#!/bin/bash
# 修改k8s命名空间deployment的容器的镜像
#读取多行deployment.name=镜像名
# namespace=tmc-v2-saas saas线上环境
# namespace=yun-cabrfire-com
# namespace=xiaofangpingtai
# namespace=tmc-v2-saas
# namespace=zhihuixiaofnag
# namespace=shanxihuadian 
# namespace=yuanweimin 
# namespace=zigong-xiaofang
# namespace=zhengshangpinganjia
# namespace=diyishifan
# namespace=guizhoujianyuan
# namespace=zhongyingyun
# namespace=tmc-v2-saas
# namespace=jiaokeyuan-tezhijia
namespace=hubeiyiweihui
if [ -z "$namespace" ]
then
  echo "namespace is null"
  exit 1
fi
cat<<EOF > image.txt
turingcloud-activiti=harbor.iot.store:8085/turing-kubesphere/turingcloud-activiti:SNAPSHOT-20
turingcloud-aircraft=harbor.iot.store:8085/turing-kubesphere/turingcloud-aircraft:SNAPSHOT-20
turingcloud-auth=harbor.iot.store:8085/turing-kubesphere/turingcloud-auth:SNAPSHOT-45
turingcloud-daemon-quartz=harbor.iot.store:8085/turing-kubesphere/turingcloud-daemon-quartz:SNAPSHOT-50
turingcloud-daily=harbor.iot.store:8085/turing-kubesphere/turingcloud-daily:SNAPSHOT-242
turingcloud-data=harbor.iot.store:8085/turing-kubesphere/turingcloud-data:SNAPSHOT-47
turingcloud-dataanalysis=harbor.iot.store:8085/turing-kubesphere/turingcloud-dataanalysis:SNAPSHOT-313
turingcloud-device=harbor.iot.store:8085/turing-kubesphere/turingcloud-device:SNAPSHOT-907
turingcloud-gateway=harbor.iot.store:8085/turing-kubesphere/turingcloud-gateway:SNAPSHOT-23
turingcloud-ground-pressure=harbor.iot.store:8085/turing-kubesphere/turingcloud-ground-pressure:SNAPSHOT-122
turingcloud-light=harbor.iot.store:8085/turing-kubesphere/turingcloud-light:SNAPSHOT-8
turingcloud-register=harbor.iot.store:8085/turing-kubesphere/turingcloud-register:latest
turingcloud-safety=harbor.iot.store:8085/turing-kubesphere/turingcloud-safety:SNAPSHOT-100
turingcloud-tx-manager=harbor.iot.store:8085/turing-kubesphere/turingcloud-tx-manager:latest
turingcloud-upms=harbor.iot.store:8085/turing-kubesphere/turingcloud-upms:SNAPSHOT-582
turingcloud-video=harbor.iot.store:8085/turing-kubesphere/turingcloud-video:SNAPSHOT-329
turingcloud-visual=harbor.iot.store:8085/turing-kubesphere/turingcloud-visual:SNAPSHOT-23
turingcloud-web=harbor.iot.store:8085/turing-kubesphere/turingcloud-web-zktl:SNAPSHOT-1317
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




