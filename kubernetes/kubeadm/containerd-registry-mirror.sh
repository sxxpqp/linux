#!/bin/bash
# containerd 镜像加速配置（国内必需）
# 用法: bash containerd-registry-mirror.sh

set -e

CERTS_DIR="/etc/containerd/certs.d"
CONTAINERD_CONF="/etc/containerd/config.toml"

# ---- 前置检查:containerd 必须已启用 config_path,否则 hosts.toml 不会被读取 ----
if ! grep -q 'config_path = "/etc/containerd/certs.d"' "${CONTAINERD_CONF}" 2>/dev/null; then
  echo "✗ ${CONTAINERD_CONF} 未启用 config_path,请先手动配置以下内容后重跑本脚本:"
  echo ""
  echo "    [plugins.\"io.containerd.grpc.v1.cri\".registry]"
  echo "      config_path = \"/etc/containerd/certs.d\""
  echo ""
  echo "  配完后 systemctl restart containerd,再跑本脚本。"
  exit 1
fi

declare -A MIRRORS=(
  ["docker.io"]="https://0523dw.ihome.sxxpqp.top:8443"
  ["ghcr.io"]="https://ghcr.ihome.sxxpqp.top:8443"
  ["registry.k8s.io"]="https://k8s.ihome.sxxpqp.top:8443"
  ["quay.io"]="https://quay.ihome.sxxpqp.top:8443"
)

for REGISTRY in "${!MIRRORS[@]}"; do
  MIRROR="${MIRRORS[$REGISTRY]}"
  DIR="${CERTS_DIR}/${REGISTRY}"
  FILE="${DIR}/hosts.toml"

  mkdir -p "${DIR}"

  cat > "${FILE}" << TOML
server = "https://${REGISTRY}"

[host."${MIRROR}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
TOML

  echo "  ✓ ${REGISTRY} → ${MIRROR}"
done

systemctl restart containerd
echo ""
echo "containerd 已重启，镜像加速生效"
