#!/bin/bash
# Rancher 重启脚本
cd "$(dirname "$0")" || exit 1
docker-compose down
docker-compose up -d
echo "Rancher 重启中... 请稍候"
echo "访问 https://<宿主机IP>:8443"
