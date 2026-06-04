#!/usr/bin/env bash
# 系统: Docker (cross-platform)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/node-cordon-watcher/build-push.sh
# 用法: bash build-push.sh [tag]
#
# 构建并推送 node-cordon-watcher 镜像到阿里云 ACR。
# 默认 tag 用 git short sha,可手动指定。

set -euo pipefail

REGISTRY="registry.cn-hangzhou.aliyuncs.com"
NAMESPACE="sxxpqp"
IMAGE="node-cordon-watcher"
TAG="${1:-$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d-%H%M%S)}"

FULL="${REGISTRY}/${NAMESPACE}/${IMAGE}:${TAG}"
LATEST="${REGISTRY}/${NAMESPACE}/${IMAGE}:latest"

echo "[1/3] 构建镜像 ${FULL}"
docker build -t "${FULL}" -t "${LATEST}" .

echo "[2/3] 检查登录态(如未登录请先 docker login ${REGISTRY})"
if ! docker info 2>/dev/null | grep -q "Username"; then
    echo "提示: docker login ${REGISTRY}  (用户名 sxxpqp)"
fi

echo "[3/3] 推送 ${FULL} 和 :latest"
docker push "${FULL}"
docker push "${LATEST}"

echo "✓ 镜像已推送: ${FULL}"
echo "  在 deploy.yaml 里更新 image: ${FULL}"
