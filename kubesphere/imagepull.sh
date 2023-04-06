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
docker save minio/minio:RELEASE.2019-08-07T01-59-21Z -o minio.tar

rsync -e "ssh -p 12121" -avz minio.tar node1:/root/minio.tar
docker load -i minio.tar
