#/bin/bash
# 备份所有image镜像
TAG=`docker image list|grep -v REPOSITORY|awk '{print $1":" $2}'`
docker save $TAG -o `hostname`.tar

TAG=`docker image list|grep -v REPOSITORY|grep harbor|awk '{print $1":" $2}'`
docker save $TAG -o `hostname`.tar