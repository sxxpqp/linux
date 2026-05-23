#!/bin/bash
# 获取源k8s命名空间deployment的容器的镜像
# 用法：./get_image.sh <namespace> <deployment>
namespace=tmc-v2-test
# namespace=tsl
# namespace=tmc-v2-saas
# shellcheck disable=SC2162
kubectl -n ${namespace} get deployment | grep -v NAME |grep turing| awk '{print $1}' | while read line
do   
# 去掉annotation字段
    # shellcheck disable=SC2086
    kubectl get deployment $line  -n ${namespace} -o yaml | grep image|grep -v "apiVersion" |grep $line| awk  '{print $NF}' | while read image
    do
      echo "$line=$image"
    done

done


