#!/bin/bash
# containerd 镜像加速配置（国内必需）
# 用法: bash containerd-registry-mirror.sh

set -e

CERTS_DIR="/etc/containerd/certs.d"

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
