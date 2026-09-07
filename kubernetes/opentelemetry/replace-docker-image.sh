#!/usr/bin/env bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/opentelemetry/replace-docker-image.sh
# 检查 YAML 中的镜像 registry；不修改 YAML image 字段。
# 用法: bash replace-docker-image.sh <manifest.yaml>

set -euo pipefail

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

MANIFEST="${1:-}"

if [[ -z "$MANIFEST" || ! -f "$MANIFEST" ]]; then
  echo "用法: bash $0 <manifest.yaml>" >&2
  exit 1
fi

if ! grep -qE '^[[:space:]]*image:' "$MANIFEST"; then
  echo "未在 ${MANIFEST} 中发现 image 字段"
  exit 0
fi

echo "发现的镜像："
grep -E '^[[:space:]]*image:' "$MANIFEST"
echo

MIRROR_REGISTRIES=(docker.io ghcr.io quay.io registry.k8s.io)
MIRROR_REQUIRED=false
for registry in "${MIRROR_REGISTRIES[@]}"; do
  if grep -qE "^[[:space:]]*image:[[:space:]]*['\"]?${registry}/" "$MANIFEST"; then
    echo "${registry}: 由 containerd hosts.toml 透明加速，不修改 YAML"
    MIRROR_REQUIRED=true
  fi
done

for registry in gcr.io mcr.microsoft.com; do
  if grep -qE "^[[:space:]]*image:[[:space:]]*['\"]?${registry}/" "$MANIFEST"; then
    echo "${registry}: 当前不在 containerd mirror 表中，不自动改写 YAML"
  fi
done

if [[ "$MIRROR_REQUIRED" == true ]]; then
  echo
  echo "请在每个节点执行:"
  echo "  bash docker/containerd/mirrors.sh && systemctl restart containerd"
fi
