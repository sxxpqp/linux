#!/bin/bash
# 把 docker-images.txt 里列出的镜像重新 tag 并推送到阿里云 ACR sxxpqp 命名空间
# 用法: bash changeimage.sh
# 前置: docker login registry.cn-hangzhou.aliyuncs.com  (用户名 sxxpqp)

ACR="registry.cn-hangzhou.aliyuncs.com/sxxpqp"

for i in `cat docker-images.txt`
do
  # 取镜像名:tag 部分(去掉 registry 前缀)
  name="${i##*/}"

  docker pull ${i}
  docker tag ${i} ${ACR}/${name}
  docker push ${ACR}/${name}
done
