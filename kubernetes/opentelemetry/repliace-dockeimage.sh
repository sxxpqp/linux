#!/bin/bash
# 替换无法拉取镜像 
# $1为需修改的文件 
#ghcr.io/修改ghcr.dockerproxy.com
sed -i 's#ghcr.io/#ghcr.dockerproxy.com/#g' $1
#gcr.io/修改gcr.dockerproxy.com
sed -i 's#gcr.io/#gcr.dockerproxy.com/#g' $1

# k8s.gcr.io/ registry.k8s.io/修改 k8s.dockerproxy.com/

sed -i 's#k8s.gcr.io/#k8s.dockerproxy.com/#g' $1
sed -i 's#registry.k8s.io/#k8s.dockerproxy.com/#g' $1

# quay.io/修改 quay.dockerproxy.com/

sed -i 's#quay.io/#quay.dockerproxy.com/#g' $1

# mcr.microsoft.com/ 修改mcr.dockerproxy.com/

sed -i 's#mcr.microsoft.com/#mcr.dockerproxy.com/#g' $1

# 查看文件拉取镜像
# cat opentelemetry-demo.yaml |grep image:|awk -F" " '{print $2}'|xargs -I {} docker pull {}
