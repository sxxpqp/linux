#!/bin/bash

# 设置一些变量
GPG_KEY_URL="https://chfs.sxxpqp.top:8443/chfs/shared/docker/nvidia/gpgkey"
KEYRING_PATH="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
LIST_URL="https://chfs.sxxpqp.top:8443/chfs/shared/docker/nvidia/nvidia-container-toolkit.list"
LIST_PATH="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

# 步骤 1: 导入 GPG 密钥
echo "导入 GPG 密钥..."
curl -fsSL "$GPG_KEY_URL" | sudo gpg --dearmor -o "$KEYRING_PATH"

# 步骤 2: 添加 NVIDIA 软件源到 APT
echo "添加 NVIDIA 容器工具包源..."
curl -s -L "$LIST_URL" -o "$LIST_PATH"

# 步骤 3: 更新 APT 并安装 NVIDIA 容器工具包
echo "更新 APT 包索引并安装 nvidia-container-toolkit..."
sudo apt update && sudo apt install -y nvidia-container-toolkit

echo "安装完成!"
