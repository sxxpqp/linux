#!/usr/bin/env bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/containerd/mirrors.sh
# 配置 containerd 全部镜像加速源
# 用法: bash mirrors.sh

set -euo pipefail

CERTS_DIR="/etc/containerd/certs.d"

# ============================================================
# docker.io → Harbor proxy
# ============================================================
mkdir -p "$CERTS_DIR/docker.io"
cat > "$CERTS_DIR/docker.io/hosts.toml" <<'EOF'
server = "https://registry-1.docker.io"

[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
echo "✓ docker.io → dockerhub.ihome.sxxpqp.top:8443"

# ============================================================
# registry.k8s.io → Harbor proxy
# ============================================================
mkdir -p "$CERTS_DIR/registry.k8s.io"
cat > "$CERTS_DIR/registry.k8s.io/hosts.toml" <<'EOF'
server = "https://registry.k8s.io"

[host."https://k8s.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
echo "✓ registry.k8s.io → k8s.ihome.sxxpqp.top:8443"

# ============================================================
# quay.io → Harbor proxy
# ============================================================
mkdir -p "$CERTS_DIR/quay.io"
cat > "$CERTS_DIR/quay.io/hosts.toml" <<'EOF'
server = "https://quay.io"

[host."https://quay.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
echo "✓ quay.io → quay.ihome.sxxpqp.top:8443"

# ============================================================
# ghcr.io → Harbor proxy
# ============================================================
mkdir -p "$CERTS_DIR/ghcr.io"
cat > "$CERTS_DIR/ghcr.io/hosts.toml" <<'EOF'
server = "https://ghcr.io"

[host."https://ghcr.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
echo "✓ ghcr.io → ghcr.ihome.sxxpqp.top:8443"

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
echo "全部加速源已配置, 列出:"
find "$CERTS_DIR" -name hosts.toml -exec echo "  {}" \;

echo ""
echo "验证(拉一个镜像测试):"
echo "  ctr -n k8s.io image pull docker.io/library/nginx:alpine"
echo "  ctr -n k8s.io image pull registry.k8s.io/pause:3.9"
echo "  ctr -n k8s.io image pull quay.io/metallb/controller:v0.14.8"
