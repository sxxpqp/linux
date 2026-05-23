#!/bin/bash 

set -e
# 安装csi-nfs
echo "开始安装 csi-nfs ..."




wget -N https://chfs.sxxpqp.top:8443/chfs/shared/k8s/csi-driver-nfs/rbac-csi-nfs.yaml
wget -N https://chfs.sxxpqp.top:8443/chfs/shared/k8s/csi-driver-nfs/csi-nfs-driver.yaml
wget -N https://chfs.sxxpqp.top:8443/chfs/shared/k8s/csi-driver-nfs/csi-nfs-node.yaml
wget -N https://chfs.sxxpqp.top:8443/chfs/shared/k8s/csi-driver-nfs/csi-nfs-controller.yaml
wget -N https://chfs.sxxpqp.top:8443/chfs/shared/k8s/csi-driver-nfs/csi-nfs-storageclass.yaml
kubectl apply -f rbac-csi-nfs.yaml
kubectl apply -f csi-nfs-driver.yaml
kubectl apply -f csi-nfs-node.yaml
kubectl apply -f csi-nfs-controller.yaml
kubectl apply -f csi-nfs-storageclass.yaml
echo "csi-nfs 安装完成 ..."