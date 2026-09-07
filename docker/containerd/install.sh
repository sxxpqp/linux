#!/usr/bin/env bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/containerd/install.sh
set -euo pipefail

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.1.3}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-1.5.1}"
RUNC_VERSION="${RUNC_VERSION:-1.1.10}"
RUNC_BINARY="${RUNC_BINARY:-runc.amd64}"
CONTAINERD_CONFIG="/etc/containerd/config.toml"
CERTS_DIR="/etc/containerd/certs.d"
CONTAINERD_PKG="containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
CNI_PLUGINS_PKG="cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz"
CONTAINERD_DOWNLOAD_URL="${CONTAINERD_DOWNLOAD_URL:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/${CONTAINERD_PKG}}"
CNI_PLUGINS_DOWNLOAD_URL="${CNI_PLUGINS_DOWNLOAD_URL:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/${CNI_PLUGINS_PKG}}"
RUNC_DOWNLOAD_URL="${RUNC_DOWNLOAD_URL:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/opencontainers/runc/releases/download/v${RUNC_VERSION}/${RUNC_BINARY}}"

case "$CONTAINERD_VERSION" in
  1.*) CONTAINERD_CONFIG_MAJOR=1 ;;
  2.*) CONTAINERD_CONFIG_MAJOR=2 ;;
  *)
    echo "ERROR: 当前脚本只显式支持 containerd 1.x 和 2.x，当前 CONTAINERD_VERSION=${CONTAINERD_VERSION}" >&2
    exit 1
    ;;
esac

echo "开始安装 containerd ${CONTAINERD_VERSION} ..."

# 下载所需应用包
wget -O "${CONTAINERD_PKG}" "${CONTAINERD_DOWNLOAD_URL}"
wget -O "${CNI_PLUGINS_PKG}" "${CNI_PLUGINS_DOWNLOAD_URL}"
wget -O "${RUNC_BINARY}" "${RUNC_DOWNLOAD_URL}"

# centos7 要升级libseccomp  runc二进制不需要这个包 静态编译了
# yum -y install https://mirrors.tuna.tsinghua.edu.cn/centos/8-stream/BaseOS/x86_64/os/Packages/libseccomp-2.5.1-1.el8.x86_64.rpm


# 创建 cni / containerd 所需目录
mkdir -p /etc/cni/net.d /opt/cni/bin /etc/containerd /usr/local "$CERTS_DIR"
# 解压 cni 二进制包
tar xf "${CNI_PLUGINS_PKG}" -C /opt/cni/bin/

# 解压 containerd
tar -xzf "${CONTAINERD_PKG}" -C /usr/local


# 创建服务启动文件
cat > /etc/systemd/system/containerd.service <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF


# 创建 Containerd 的配置文件
cp /usr/local/bin/containerd /usr/bin/containerd
containerd config default > "$CONTAINERD_CONFIG"
echo "已生成 $CONTAINERD_CONFIG"

# 修改 Containerd 的配置文件
insert_after_toml_section() {
  local section="$1"
  local line="$2"
  local tmp="${CONTAINERD_CONFIG}.tmp"

  awk -v section="$section" -v line="$line" '
    {
      section_line = $0
      sub(/^[[:space:]]*/, "", section_line)
      sub(/[[:space:]]*$/, "", section_line)
    }
    section_line == section {
      print
      print line
      found = 1
      next
    }
    { print }
    END { exit found ? 0 : 1 }
  ' "$CONTAINERD_CONFIG" > "$tmp" && mv "$tmp" "$CONTAINERD_CONFIG"
}

ensure_systemd_cgroup() {
  if grep -qE '^[[:space:]]*SystemdCgroup[[:space:]]*=' "$CONTAINERD_CONFIG"; then
    sed -i -E 's#^([[:space:]]*)SystemdCgroup[[:space:]]*=.*#\1SystemdCgroup = true#' "$CONTAINERD_CONFIG"
    return
  fi

  if grep -Fq '[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]' "$CONTAINERD_CONFIG"; then
    insert_after_toml_section '[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]' '            SystemdCgroup = true'
    return
  fi

  if grep -Fq "[plugins.'io.containerd.grpc.v1.cri'.containerd.runtimes.runc.options]" "$CONTAINERD_CONFIG"; then
    insert_after_toml_section "[plugins.'io.containerd.grpc.v1.cri'.containerd.runtimes.runc.options]" '            SystemdCgroup = true'
    return
  fi

  if grep -Fq '[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]' "$CONTAINERD_CONFIG"; then
    insert_after_toml_section '[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]' '            SystemdCgroup = true'
    return
  fi

  if grep -Fq "[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]" "$CONTAINERD_CONFIG"; then
    insert_after_toml_section "[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]" '            SystemdCgroup = true'
    return
  fi

  case "$CONTAINERD_CONFIG_MAJOR" in
    1)
      cat >> "$CONTAINERD_CONFIG" <<'EOF'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
      ;;
    *)
      cat >> "$CONTAINERD_CONFIG" <<'EOF'

[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
      ;;
  esac
}

ensure_sandbox_image() {
  local pause_image

  case "$CONTAINERD_CONFIG_MAJOR" in
    1) pause_image="${PAUSE_IMAGE:-registry.aliyuncs.com/google_containers/pause:3.8}" ;;
    *) pause_image="${PAUSE_IMAGE:-registry.aliyuncs.com/google_containers/pause:3.10}" ;;
  esac

  if grep -qE '^[[:space:]]*sandbox_image[[:space:]]*=' "$CONTAINERD_CONFIG"; then
    sed -i -E "s#^([[:space:]]*)sandbox_image[[:space:]]*=.*#\1sandbox_image = \"${pause_image}\"#" "$CONTAINERD_CONFIG"
    return
  fi

  if grep -qE '^[[:space:]]*sandbox[[:space:]]*=' "$CONTAINERD_CONFIG"; then
    sed -i -E "s#^([[:space:]]*)sandbox[[:space:]]*=.*#\1sandbox = \"${pause_image}\"#" "$CONTAINERD_CONFIG"
    return
  fi

  if grep -Fq '[plugins."io.containerd.grpc.v1.cri"]' "$CONTAINERD_CONFIG"; then
    insert_after_toml_section '[plugins."io.containerd.grpc.v1.cri"]' "  sandbox_image = \"${pause_image}\""
    return
  fi

  if grep -Fq "[plugins.'io.containerd.grpc.v1.cri']" "$CONTAINERD_CONFIG"; then
    insert_after_toml_section "[plugins.'io.containerd.grpc.v1.cri']" "  sandbox_image = \"${pause_image}\""
    return
  fi

  if grep -Fq '[plugins."io.containerd.cri.v1.images".pinned_images]' "$CONTAINERD_CONFIG"; then
    insert_after_toml_section '[plugins."io.containerd.cri.v1.images".pinned_images]' "  sandbox = \"${pause_image}\""
    return
  fi

  if grep -Fq "[plugins.'io.containerd.cri.v1.images'.pinned_images]" "$CONTAINERD_CONFIG"; then
    insert_after_toml_section "[plugins.'io.containerd.cri.v1.images'.pinned_images]" "  sandbox = \"${pause_image}\""
    return
  fi

  case "$CONTAINERD_CONFIG_MAJOR" in
    1)
      cat >> "$CONTAINERD_CONFIG" <<EOF

[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "${pause_image}"
EOF
      ;;
    *)
      cat >> "$CONTAINERD_CONFIG" <<EOF

[plugins."io.containerd.cri.v1.images".pinned_images]
  sandbox = "${pause_image}"
EOF
      ;;
  esac
}

ensure_config_path() {
  if grep -qE '^[[:space:]]*config_path[[:space:]]*=' "$CONTAINERD_CONFIG"; then
    sed -i -E "s#^([[:space:]]*)config_path[[:space:]]*=.*#\1config_path = \"${CERTS_DIR}\"#" "$CONTAINERD_CONFIG"
    return
  fi

  if grep -Fq '[plugins."io.containerd.grpc.v1.cri".registry]' "$CONTAINERD_CONFIG"; then
    insert_after_toml_section '[plugins."io.containerd.grpc.v1.cri".registry]' "  config_path = \"${CERTS_DIR}\""
    return
  fi

  if grep -Fq "[plugins.'io.containerd.grpc.v1.cri'.registry]" "$CONTAINERD_CONFIG"; then
    insert_after_toml_section "[plugins.'io.containerd.grpc.v1.cri'.registry]" "  config_path = \"${CERTS_DIR}\""
    return
  fi

  if grep -Fq '[plugins."io.containerd.cri.v1.images".registry]' "$CONTAINERD_CONFIG"; then
    insert_after_toml_section '[plugins."io.containerd.cri.v1.images".registry]' "  config_path = \"${CERTS_DIR}\""
    return
  fi

  if grep -Fq "[plugins.'io.containerd.cri.v1.images'.registry]" "$CONTAINERD_CONFIG"; then
    insert_after_toml_section "[plugins.'io.containerd.cri.v1.images'.registry]" "  config_path = \"${CERTS_DIR}\""
    return
  fi

  case "$CONTAINERD_CONFIG_MAJOR" in
    1)
      cat >> "$CONTAINERD_CONFIG" <<EOF

[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "${CERTS_DIR}"
EOF
      ;;
    *)
      cat >> "$CONTAINERD_CONFIG" <<EOF

[plugins."io.containerd.cri.v1.images".registry]
  config_path = "${CERTS_DIR}"
EOF
      ;;
  esac
}

ensure_systemd_cgroup
ensure_sandbox_image
ensure_config_path

grep -nE 'SystemdCgroup|systemd_cgroup' "$CONTAINERD_CONFIG" || { echo "ERROR: 未写入 SystemdCgroup" >&2; exit 1; }
grep -nE 'sandbox_image|sandbox =' "$CONTAINERD_CONFIG" || { echo "ERROR: 未写入 sandbox_image" >&2; exit 1; }
grep -nE 'config_path|certs\.d' "$CONTAINERD_CONFIG" || { echo "ERROR: 未写入 config_path" >&2; exit 1; }
echo "已开启 containerd certs.d mirror 配置目录: $CERTS_DIR"
echo "下一步: bash docker/containerd/mirrors.sh && systemctl restart containerd"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter


cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl --system

chmod +x "${RUNC_BINARY}"
# 覆盖 mv
mv -f "${RUNC_BINARY}" /usr/local/sbin/runc

# 启动并设置为开机启动
systemctl daemon-reload
systemctl enable containerd.service
systemctl restart containerd.service
systemctl --no-pager status containerd.service

echo "containerd 安装完成"
