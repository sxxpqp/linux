#!/bin/bash
# 获取源k8s命名空间deployment的容器的镜像
# 用法：./get_image.sh <namespace> <deployment>
namespace=tmc-v2-test
kubectl -n ${namespace} get deployment | grep -v NAME |grep turing| awk '{print $1}' | while read line
do   
# 去掉annotation字段
    kubectl get deployment $line  -n ${namespace} -o yaml | grep image|grep -v "apiVersion" |grep $line| awk  '{print $NF}' | while read image
    do
      echo "$line=$image"
    done

done


turingcloud-activiti=harbor.iot.store:8085/turing-kubesphere/turingcloud-activiti:SNAPSHOT-20
turingcloud-aircraft=harbor.iot.store:8085/turing-kubesphere/turingcloud-aircraft:SNAPSHOT-18
turingcloud-auth=harbor.iot.store:8085/turing-kubesphere/turingcloud-auth:SNAPSHOT-43
turingcloud-daemon-quartz=harbor.iot.store:8085/turing-kubesphere/turingcloud-daemon-quartz:SNAPSHOT-50
turingcloud-daily=harbor.iot.store:8085/turing-kubesphere/turingcloud-daily:SNAPSHOT-236
turingcloud-data=harbor.iot.store:8085/turing-kubesphere/turingcloud-data:SNAPSHOT-43
turingcloud-dataanalysis=harbor.iot.store:8085/turing-kubesphere/turingcloud-dataanalysis:SNAPSHOT-303
turingcloud-device=harbor.iot.store:8085/turing-kubesphere/turingcloud-device:SNAPSHOT-863
turingcloud-gateway=harbor.iot.store:8085/turing-kubesphere/turingcloud-gateway:SNAPSHOT-23
turingcloud-ground-pressure=harbor.iot.store:8085/turing-kubesphere/turingcloud-ground-pressure:SNAPSHOT-92
turingcloud-light=harbor.iot.store:8085/turing-kubesphere/turingcloud-light:SNAPSHOT-8
turingcloud-register=harbor.iot.store:8085/turing-kubesphere/turingcloud-register:latest
turingcloud-safety=harbor.iot.store:8085/turing-kubesphere/turingcloud-safety:SNAPSHOT-91
turingcloud-tx-manager=harbor.iot.store:8085/turing-kubesphere/turingcloud-tx-manager:latest
turingcloud-upms=harbor.iot.store:8085/turing-kubesphere/turingcloud-upms:SNAPSHOT-526
turingcloud-video=harbor.iot.store:8085/turing-kubesphere/turingcloud-video:SNAPSHOT-308
turingcloud-visual=harbor.iot.store:8085/turing-kubesphere/turingcloud-visual:SNAPSHOT-23
turingcloud-web=harbor.iot.store:8085/turing-kubesphere/turingcloud-web-zktl:SNAPSHOT-1265