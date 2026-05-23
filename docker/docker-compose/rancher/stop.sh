#!/bin/bash
# Rancher 停止脚本
cd "$(dirname "$0")" || exit 1
docker-compose down
echo "Rancher 已停止"
