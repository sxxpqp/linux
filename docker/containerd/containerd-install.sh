# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/containerd/containerd-install.sh
#!/usr/bin/env bash
set -euo pipefail

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

echo "开始安装 containerd ..."

CONTAINERD_PKG_BASE_URL="${CONTAINERD_PKG_BASE_URL:-https://chfs.sxxpqp.top:8443/chfs/shared/docker/containerd}"
CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7.18}"
CNI_PLUGINS_VERSION="${CNI_PLUGINS_VERSION:-1.5.1}"
RUNC_BINARY="${RUNC_BINARY:-runc.amd64}"
CONTAINERD_CONFIG="/etc/containerd/config.toml"
CERTS_DIR="/etc/containerd/certs.d"
CRI_CONTAINERD_CNI_PKG="cri-containerd-cni-${CONTAINERD_VERSION}-linux-amd64.tar.gz"
CNI_PLUGINS_PKG="cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz"

# 下载所需应用包
wget -O "${CRI_CONTAINERD_CNI_PKG}" "${CONTAINERD_PKG_BASE_URL}/${CRI_CONTAINERD_CNI_PKG}"
wget -O "${CNI_PLUGINS_PKG}" "${CONTAINERD_PKG_BASE_URL}/${CNI_PLUGINS_PKG}"
wget -O "${RUNC_BINARY}" "${CONTAINERD_PKG_BASE_URL}/${RUNC_BINARY}"

# centos7 要升级libseccomp  runc二进制不需要这个包 静态编译了
# yum -y install https://mirrors.tuna.tsinghua.edu.cn/centos/8-stream/BaseOS/x86_64/os/Packages/libseccomp-2.5.1-1.el8.x86_64.rpm


# 创建 cni / containerd 所需目录
mkdir -p /etc/cni/net.d /opt/cni/bin /etc/containerd "$CERTS_DIR/docker.io"
# 解压 cni 二进制包
tar xf "${CNI_PLUGINS_PKG}" -C /opt/cni/bin/

# 解压 containerd
tar -xzf "${CRI_CONTAINERD_CNI_PKG}" -C /


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
containerd config default | tee "$CONTAINERD_CONFIG"

# 修改 Containerd 的配置文件
sed -i "s#SystemdCgroup\ \=\ false#SystemdCgroup\ \=\ true#g" "$CONTAINERD_CONFIG"
grep SystemdCgroup "$CONTAINERD_CONFIG"
sed -i "s#registry.k8s.io#registry.aliyuncs.com/google_containers#g" "$CONTAINERD_CONFIG"
grep sandbox_image "$CONTAINERD_CONFIG"
sed -i "s#config_path\ \=\ \"\"#config_path\ \=\ \"$CERTS_DIR\"#g" "$CONTAINERD_CONFIG"
grep certs.d "$CONTAINERD_CONFIG"


# 配置加速器
cat > "$CERTS_DIR/docker.io/hosts.toml" << EOF
server = "https://registry-1.docker.io"
[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF


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
