#!/bin/bash

# Helm 安装脚本
HELM_VERSION="v4.1.0"
DOWNLOAD_URL="https://chfs.sxxpqp.top:8443/chfs/shared/k8s/helm/helm-${HELM_VERSION}-linux-amd64.tar.gz"
INSTALL_DIR="/usr/local/bin"

echo "=== 下载 Helm ${HELM_VERSION} ==="
curl -LO "$DOWNLOAD_URL"

echo "=== 解压到环境变量目录：$INSTALL_DIR ==="
mkdir -p "$INSTALL_DIR"
tar -xzf "helm-${HELM_VERSION}-linux-amd64.tar.gz"
mv linux-amd64/helm "$INSTALL_DIR/"
rm -rf linux-amd64 "helm-${HELM_VERSION}-linux-amd64.tar.gz"

echo "=== 验证安装 ==="
helm version

echo "=== 安装完成 ==="
echo "请确保 $INSTALL_DIR 已添加到 PATH 环境变量"
