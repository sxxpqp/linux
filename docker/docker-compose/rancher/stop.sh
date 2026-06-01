#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/docker-compose/rancher/stop.sh
# Rancher 停止脚本
cd "$(dirname "$0")" || exit 1
docker-compose down
echo "Rancher 已停止"
