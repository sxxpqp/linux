#!/usr/bin/env bash
# 系统: Linux (Docker)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/image/image.sh
# 用法: bash docker/image/image.sh

set -euo pipefail
# 备份所有image镜像
TAG=`docker image list|grep -v REPOSITORY|awk '{print $1":" $2}'`
docker save $TAG -o `hostname`.tar

TAG=`docker image list|grep -v REPOSITORY|grep harbor|awk '{print $1":" $2}'`
docker save $TAG -o `hostname`.tar