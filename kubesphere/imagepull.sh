#!/bin/bash
deploy=(ks-apiserver ks-console ks-controller-manager ks-installer minio)         
for i in ${deploy[@]}; do
    kubectl -n kubesphere-system patch deployment $i -p '{"spec":{"template":{"spec":{"containers":[{"name":"'$i'","imagePullPolicy":"IfNotPresent"}]}}}}'
    
done

deploy=(ks-apiserver ks-console ks-controller-manager ks-installer minio)         
for i in ${deploy[@]}; do
    

docker tag registry.cn-beijing.aliyuncs.com/kubesphereio/$i:v3.2.0 kubesphere/$i:v3.2.0
done


//同步镜像

node=(node1 node2 node3 node4)
for i in ${node[@]}; do
    rsync -e "ssh -p 12121" -avz k8s-device-plugin.tar $i:/root/k8s-device-plugin.tar
done

docker load -i /root/k8s-device-plugin.tar