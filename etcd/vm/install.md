## 安装部署etcd集群
### 主机名与ip对应关系
```
主机名      ip
etcd1   192.168.1.43
etcd2   192.168.1.44 
etcd3   192.168.1.45
```

### 2.2.2. 安装etcd
```
yum install etcd -y
systemctl stop firewalld && systemctl disable firewalld
```

### 2.2.3. etcd1配置etcd
```
cat > /etc/etcd/etcd.conf<<EOF
ETCD_NAME=etcd1
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://0.0.0.0:2380"
ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://192.168.1.43:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://192.168.1.43:2380"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_INITIAL_CLUSTER="etcd1=http://192.168.1.43:2380,etcd2=http://192.168.1.44:2380,etcd3=http://192.168.1.45:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF
```

### 2.2.4. etcd2配置etcd
```
cat > /etc/etcd/etcd.conf<<EOF
ETCD_NAME=etcd2
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://0.0.0.0:2380"
ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://192.168.1.44:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://192.168.1.44:2380"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_INITIAL_CLUSTER="etcd1=http://192.168.1.43:2380,etcd2=http://192.168.1.44:2380,etcd3=http://192.168.1.45:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF
```
### 2.2.5. etcd3配置etcd
```
cat > /etc/etcd/etcd.conf<<EOF
ETCD_NAME=etcd3
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://0.0.0.0:2380"
ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://192.168.1.45:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://192.168.1.45:2380"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster"
ETCD_INITIAL_CLUSTER="etcd1=http://192.168.1.43:2380,etcd2=http://192.168.1.44:2380,etcd3=http://192.168.1.45:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
EOF
```
### 2.2.6. 启动etcd
```
systemctl daemon-reload
systemctl enable etcd
systemctl start etcd
```
### 2.2.7. 验证etcd
```
etcdctl endpoint status
```


### 重置etcd集群
```
rm -rf /var/lib/etcd/default.etcd
sed -i 's/ETCD_INITIAL_CLUSTER_STATE="existing"/ETCD_INITIAL_CLUSTER_STATE="new"/g' /etc/etcd/etcd.conf
systemctl restart etcd
```


## etcd3数据丢失后恢复
```
# 删除etcd3节点
etcdctl member remove 2c4e2f7b4f2b4e2a
# 添加etcd3节点
etcdctl member add etcd3 http://192.1681.45:2380

#返回的信息
#ETCD_NAME="etcd3"
#ETCD_INITIAL_CLUSTER="etcd3=http://192.168.1.45:2380,etcd2=http://192.168.1.44:2380,etcd1=http://192.168.1.43:2380"
#ETCD_INITIAL_CLUSTER_STATE="existing"
# 修改etcd3配置文件
sed -i 's/ETCD_INITIAL_CLUSTER_STATE="new"/ETCD_INITIAL_CLUSTER_STATE="existing"/g' /etc/etcd/etcd.conf

# 重启etcd3
systemctl restart etcd

# 查看集群状态
etcdctl endpoint status
etcdctl cluster-health
etcdctl member list
```

## 备份etcd
```
# 备份
ETCDCTL_API=3 etcdctl  --endpoints=http://192.168.1.43:2379 snapshot save  /tmp/etcd-backup/etcd-snapshot.db 


```
## 恢复备份
```
systemctl stop etcd
rm -rf /var/lib/etcd/default.etcd
mv /var/lib/etcd/default.etcd /var/lib/etcd/default.etcd.bak
```

### k8s-master1 机器上操作.
```
ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup/etcd-snapshot.db \
--name etcd1 \
--initial-cluster etcd1=http://192.168.1.43:2380,etcd2=http://192.168.1.44:2380,etcd3=http://192.168.1.45:2380 \
--initial-cluster-token etcd-cluster \
--initial-advertise-peer-urls http://192.168.1.43:2380 \
--data-dir=/var/lib/etcd/default.etcd
```  
### k8s-master2 机器上操作
```
scp /tmp/etcd-backup/etcd-snapshot.db root@192.168.1.44:/tmp/etcd-backup/
```
```
ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup/etcd-snapshot.db \
  --name etcd2 \
  --initial-cluster etcd1=http://192.168.1.43:2380,etcd2=http://192.168.1.44:2380,etcd3=http://192.168.1.45:2380 \
  --initial-cluster-token etcd-cluster \
  --initial-advertise-peer-urls http://192.168.1.44:2380 \
  --data-dir=/var/lib/etcd/default.etcd
``` 
  
### k8s-master3 机器上操作
```
scp /tmp/etcd-backup/etcd-snapshot.db root@192.168.1.45:/tmp/etcd-backup/
```  
```
ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup/etcd-snapshot.db \
  --name etcd3 \
  --initial-cluster etcd1=http://192.168.1.43:2380,etcd2=http://192.168.1.44:2380,etcd3=http://192.168.1.45:2380 \
  --initial-cluster-token etcd-cluster \
  --initial-advertise-peer-urls http://192.168.1.45:2380 \
  --data-dir=/var/lib/etcd/default.etcd
```

sed -i 's/ETCD_INITIAL_CLUSTER_STATE="new"/ETCD_INITIAL_CLUSTER_STATE="existing"/g' /etc/etcd/etcd.conf
chown etcd:etcd -R /var/lib/etcd/default.etcd
systemctl restart etcd
etcdctl cluster-health
```

# 查找etcd中所有的key
```
ETCDCTL_API=3 etcdctl --endpoints=http://192.168.1.43:2379 get / --prefix --keys-only 
```

# 设置etcd的key
```
ETCDCTL_API=3 etcdctl --endpoints=http://192.168.1.43:2379 put pqp "sxx"
```



