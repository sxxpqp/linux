#!/bin/bash
# 修改k8s命名空间deployment的容器的镜像
#读取多行deployment.name=镜像名
namespace=zhongkeweizhen
if [ -z "$namespace" ]
then
  echo "namespace is null"
  exit 1
fi
cat<<EOF > image.txt
turingcloud-activiti=harbor.iot.store:8085/turing-kubesphere/turingcloud-activiti:SNAPSHOT-20
turingcloud-auth=harbor.iot.store:8085/turing-kubesphere/turingcloud-auth:SNAPSHOT-40
turingcloud-daemon-quartz=harbor.iot.store:8085/turing-kubesphere/turingcloud-daemon-quartz:SNAPSHOT-49
turingcloud-daily=harbor.iot.store:8085/turing-kubesphere/turingcloud-daily:SNAPSHOT-231
turingcloud-data=harbor.iot.store:8085/turing-kubesphere/turingcloud-data:SNAPSHOT-37
turingcloud-dataanalysis=harbor.iot.store:8085/turing-kubesphere/turingcloud-dataanalysis:SNAPSHOT-303
turingcloud-device=harbor.iot.store:8085/turing-kubesphere/turingcloud-device:SNAPSHOT-776
turingcloud-gateway=harbor.iot.store:8085/turing-kubesphere/turingcloud-gateway:SNAPSHOT-23
turingcloud-ground-pressure=harbor.iot.store:8085/turing-kubesphere/turingcloud-ground-pressure:SNAPSHOT-48
turingcloud-light=harbor.iot.store:8085/turing-kubesphere/turingcloud-light:SNAPSHOT-6
turingcloud-register=harbor.iot.store:8085/turing-kubesphere/turingcloud-register:latest
turingcloud-safety=harbor.iot.store:8085/turing-kubesphere/turingcloud-safety:SNAPSHOT-87
turingcloud-tx-manager=harbor.iot.store:8085/turing-kubesphere/turingcloud-tx-manager:latest
turingcloud-upms=harbor.iot.store:8085/turing-kubesphere/turingcloud-upms:SNAPSHOT-466
turingcloud-video=harbor.iot.store:8085/turing-kubesphere/turingcloud-video:SNAPSHOT-263
turingcloud-visual=harbor.iot.store:8085/turing-kubesphere/turingcloud-visual:SNAPSHOT-23
turingcloud-web=harbor.iot.store:8085/turing-kubesphere/turingcloud-web-zktl:SNAPSHOT-1169
EOF
# 通过输入参数获取deployment.name=镜像名
while read line
do
  app=`echo $line | awk -F '=' '{print $1}'`
  image=`echo $line | awk -F '=' '{print $2}'`
  echo "app=$app"
  echo "image=$image"
#   Error: flags cannot be placed before plugin name: -n
#   kubectl set image deployment/$app $app=$image -n ${namespace}
    kubectl set image deployment/$app $app=$image --namespace=${namespace}
done < image.txt