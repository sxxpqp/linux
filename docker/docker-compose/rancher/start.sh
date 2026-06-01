#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/docker-compose/rancher/start.sh
# Rancher 启动脚本
cd "$(dirname "$0")" || exit 1
docker-compose up -d
echo "Rancher 启动中... 请稍候"
echo "访问 https://<宿主机IP>:8443"
