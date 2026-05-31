#!/bin/bash 

set -e
# 安装csi-nfs
echo "开始安装 csi-nfs ..."




wget -N https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/csi-driver-nfs-aliyun/rbac-csi-nfs.yaml
wget -N https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/csi-driver-nfs-aliyun/csi-nfs-driver.yaml
wget -N https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/csi-driver-nfs-aliyun/csi-nfs-node.yaml
wget -N https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/csi-driver-nfs-aliyun/csi-nfs-controller.yaml
wget -N https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/csi-driver-nfs-aliyun/csi-nfs-storageclass.yaml
kubectl apply -f rbac-csi-nfs.yaml
kubectl apply -f csi-nfs-driver.yaml
kubectl apply -f csi-nfs-node.yaml
kubectl apply -f csi-nfs-controller.yaml
kubectl apply -f csi-nfs-storageclass.yaml
echo "csi-nfs 安装完成 ..."