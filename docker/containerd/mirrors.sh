#!/usr/bin/env bash
# 系统: Linux / kind 节点容器 (containerd)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/containerd/mirrors.sh
# 配置 containerd 全部镜像加速源, 每个节点跑一次。
# 用法: bash mirrors.sh
# kind 旧节点兼容: bash mirrors.sh --kind-config（备份后启用 certs.d，不重启服务）
#
# ============================================================
#  加速源完整映射(统一 Harbor Proxy Cache + 旧 K8s 别名 + ACR direct)
# ============================================================
#
#  docker.io            → huball.ihome.sxxpqp.top:8443/v2/dockerhub
#  registry.k8s.io      → huball.ihome.sxxpqp.top:8443/v2/google_containers
#  k8s.gcr.io           → huball.ihome.sxxpqp.top:8443/v2/google_containers
#  quay.io              → huball.ihome.sxxpqp.top:8443/v2/quay
#  ghcr.io              → huball.ihome.sxxpqp.top:8443/v2/ghcr
#
#  自建服务:
#  registry.cn-hangzhou.aliyuncs.com/sxxpqp/  → 阿里云 ACR(直连,推送目标)
#  nexus.ihome.sxxpqp.top:8443               → Nexus 私服(raw/helm/二进制)
#  chfs.sxxpqp.top:8443                      → 个人文件中转
#  ihome.sxxpqp.top:8443                     → MinIO S3 API
#
#  每个 upstream 对应 /etc/containerd/certs.d/<upstream>/hosts.toml
# ============================================================

set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

# 仅显式 kind 模式处理旧节点的 legacy mirrors；普通节点执行行为不变。
if [[ "${1:-}" == --kind-config ]]; then
  [[ $# == 1 && -d /kind ]] || { echo 'ERROR: --kind-config 仅允许在 kind 节点内执行' >&2; exit 1; }
  config=/etc/containerd/config.toml
  grep -F '[plugins."io.containerd.grpc.v1.cri".registry]' "$config" >/dev/null \
    || { echo 'ERROR: 未识别的 kind containerd 配置，停止修改' >&2; exit 1; }
  backup=$(mktemp -d /etc/containerd/kind-mirrors-backup.XXXXXXXX)
  cp -a "$config" "$backup/config.toml"
  if [[ -d /etc/containerd/certs.d ]]; then cp -a /etc/containerd/certs.d "$backup/"; fi
  awk '
    /^[[:space:]]*\[/ {
      registry = ($0 ~ /^[[:space:]]*\[plugins\."io.containerd.grpc.v1.cri"\.registry\][[:space:]]*$/)
      legacy = ($0 ~ /^[[:space:]]*\[plugins\."io.containerd.grpc.v1.cri"\.registry\.mirrors(\.|\])/)
    }
    legacy {next}
    registry && /^[[:space:]]*config_path[[:space:]]*=/ {next}
    {print}
    registry && /^[[:space:]]*\[/ {print "  config_path = \"/etc/containerd/certs.d\""}
  ' "$config" > "$backup/config.new.toml"
  containerd --config "$backup/config.new.toml" config dump >/dev/null
  cat "$backup/config.new.toml" > "$config"
  echo "✓ kind containerd 已启用 certs.d，原配置备份: $backup"
elif [[ $# != 0 ]]; then
  echo '用法: bash mirrors.sh [--kind-config]' >&2
  exit 1
fi

# 可指定临时目录验证生成结果；正常节点执行保持默认路径。
CERTS_DIR="${CERTS_DIR:-/etc/containerd/certs.d}"

# ============================================================
# docker.io → Harbor proxy
# ============================================================
mkdir -p "$CERTS_DIR/docker.io"
cat > "$CERTS_DIR/docker.io/hosts.toml" <<'EOF'
server = "https://registry-1.docker.io"

[host."https://huball.ihome.sxxpqp.top:8443/v2/dockerhub"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
  override_path = true
EOF
echo "✓ docker.io → huball.ihome.sxxpqp.top:8443/v2/dockerhub"

# ============================================================
# registry.k8s.io → Harbor proxy
# ============================================================
mkdir -p "$CERTS_DIR/registry.k8s.io"
cat > "$CERTS_DIR/registry.k8s.io/hosts.toml" <<'EOF'
server = "https://registry.k8s.io"

[host."https://huball.ihome.sxxpqp.top:8443/v2/google_containers"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
  override_path = true
EOF
echo "✓ registry.k8s.io → huball.ihome.sxxpqp.top:8443/v2/google_containers"

# 旧 K8s 域名，与安装菜单保持一致。
mkdir -p "$CERTS_DIR/k8s.gcr.io"
cat > "$CERTS_DIR/k8s.gcr.io/hosts.toml" <<'EOF'
server = "https://k8s.gcr.io"

[host."https://huball.ihome.sxxpqp.top:8443/v2/google_containers"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
  override_path = true
EOF
echo "✓ k8s.gcr.io → huball.ihome.sxxpqp.top:8443/v2/google_containers"

# ============================================================
# quay.io → Harbor proxy
# ============================================================
mkdir -p "$CERTS_DIR/quay.io"
cat > "$CERTS_DIR/quay.io/hosts.toml" <<'EOF'
server = "https://quay.io"

[host."https://huball.ihome.sxxpqp.top:8443/v2/quay"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
  override_path = true
EOF
echo "✓ quay.io → huball.ihome.sxxpqp.top:8443/v2/quay"

# ============================================================
# ghcr.io → Harbor proxy
# ============================================================
mkdir -p "$CERTS_DIR/ghcr.io"
cat > "$CERTS_DIR/ghcr.io/hosts.toml" <<'EOF'
server = "https://ghcr.io"

[host."https://huball.ihome.sxxpqp.top:8443/v2/ghcr"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
  override_path = true
EOF
echo "✓ ghcr.io → huball.ihome.sxxpqp.top:8443/v2/ghcr"

# ============================================================
# 阿里云 ACR(国内加速,自建 push 目标)
# ============================================================
mkdir -p "$CERTS_DIR/registry.cn-hangzhou.aliyuncs.com"
cat > "$CERTS_DIR/registry.cn-hangzhou.aliyuncs.com/hosts.toml" <<'EOF'
server = "https://registry.cn-hangzhou.aliyuncs.com"
EOF
echo "✓ registry.cn-hangzhou.aliyuncs.com (直连)"

# ============================================================
# 确认 config.toml 已开 hosts.toml 读取
# ============================================================
if grep -q 'config_path.*certs.d' /etc/containerd/config.toml 2>/dev/null; then
  echo "✓ config.toml config_path = /etc/containerd/certs.d (已是)"
else
  echo "⚠ config.toml 未开 certs.d, 手动加:"
  echo "  sed -i 's|config_path = \"\"|config_path = \"/etc/containerd/certs.d\"|' /etc/containerd/config.toml"
  echo "  systemctl restart containerd"
fi

echo ""
echo "=================================="
echo "  加速源映射(全部):"
echo "=================================="
echo "  docker.io            → huball.ihome.sxxpqp.top:8443/v2/dockerhub"
echo "  registry.k8s.io      → huball.ihome.sxxpqp.top:8443/v2/google_containers"
echo "  k8s.gcr.io           → huball.ihome.sxxpqp.top:8443/v2/google_containers"
echo "  quay.io              → huball.ihome.sxxpqp.top:8443/v2/quay"
echo "  ghcr.io              → huball.ihome.sxxpqp.top:8443/v2/ghcr"
echo
echo "自建服务:"
echo "  registry.cn-hangzhou.aliyuncs.com/sxxpqp/  (阿里云 ACR 推送)"
echo "  nexus.ihome.sxxpqp.top:8443               (Nexus raw/helm)"
echo "  chfs.sxxpqp.top:8443                      (文件中转)"
echo "  ihome.sxxpqp.top:8443                     (MinIO S3)"
echo
echo "配置目录:"
find "$CERTS_DIR" -name hosts.toml -exec echo "  {}" \;

echo ""
echo "验证:"
echo "  crictl pull docker.io/library/busybox:1.36"
echo "  crictl pull registry.k8s.io/pause:3.9"
echo "  crictl pull quay.io/prometheus/busybox:latest"
echo "  crictl pull ghcr.io/dexidp/dex:v2.41.1"
