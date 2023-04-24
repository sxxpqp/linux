#!/bin/bash

ETCDCTL_PATH='/usr/local/bin/etcdctl'
ENDPOINTS='https://192.168.1.57:2379' //etcd1 需要修改自己的IP
ETCD_DATA_DIR="/var/lib/etcd"
BACKUP_DIR="/var/backups/kube_etcd/etcd-$(date +%Y-%m-%d-%H-%M-%S)"
KEEPBACKUPNUMBER='6'
ETCDBACKUPSCIPT='/usr/local/bin/kube-scripts'

ETCDCTL_CERT="/etc/ssl/etcd/ssl/admin-node1.pem"
ETCDCTL_KEY="/etc/ssl/etcd/ssl/admin-node1-key.pem"
ETCDCTL_CA_FILE="/etc/ssl/etcd/ssl/ca.pem"
systemctl stop etcd
mv /var/lib/etcd /var/lib/etcd.bak
// 获取etcd集群的状态
etcdctl --endpoints="$ENDPOINTS" --cacert="$ETCDCTL_CA_FILE" --cert="$ETCDCTL_CERT" --key="$ETCDCTL_KEY" cluster-health
//恢复etcd集群
ETCDCTL_API=3 etcdctl snapshot restore  /var/backups/kube_etcd/etcd-2023-04-18-23-51-20/snapshot.db \
--name etcd-node1 \
--initial-cluster etcd-node1=https://192.168.1.57:2380,etcd-node2=https://192.168.1.58:2380,etcd-node3=https://192.168.1.59:2380 \
--initial-cluster-token k8s_etcd \
--initial-advertise-peer-urls https://192.168.1.57:2380 \
--data-dir /var/lib/etcd 

ETCDCTL_API=3 etcdctl snapshot restore  /var/backups/kube_etcd/etcd-2023-04-18-23-51-20/snapshot.db \
--name etcd-node2 \
--initial-cluster etcd-node1=https://192.168.1.57:2380,etcd-node2=https://192.168.1.58:2380,etcd-node3=https://192.168.1.59:2380 \
--initial-cluster-token k8s_etcd \
--initial-advertise-peer-urls https://192.168.1.58:2380 \
--data-dir /var/lib/etcd 

ETCDCTL_API=3 etcdctl snapshot restore  /var/backups/kube_etcd/etcd-2023-04-18-23-51-20/snapshot.db \
--name etcd-node3 \
--initial-cluster etcd-node1=https://192.168.1.57:2380,etcd-node2=https://192.168.1.58:2380,etcd-node3=https://192.168.1.59:2380 \
--initial-cluster-token k8s_etcd \
--initial-advertise-peer-urls https://192.168.1.59:2380 \
--data-dir /var/lib/etcd 

//启动etcd集群
systemctl start etcd
