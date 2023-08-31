## 设置节点对应变量 需要在每台设备执行 
```
TOKEN=token-01
CLUSTER_STATE=new
NAME_1=etcd-1
NAME_2=etcd-2
NAME_3=etcd-3
HOST_1=192.168.1.43
HOST_2=192.168.1.44
HOST_3=192.168.1.45
CLUSTER=${NAME_1}=http://${HOST_1}:2380,${NAME_2}=http://${HOST_2}:2380,${NAME_3}=http://${HOST_3}:2380
```
## 命令部署etcd集群(测试使用)
### For machine 1
```
THIS_NAME=${NAME_1}
THIS_IP=${HOST_1}
etcd --data-dir=data.etcd --name ${THIS_NAME} \
	--initial-advertise-peer-urls http://${THIS_IP}:2380 --listen-peer-urls http://${THIS_IP}:2380 \
	--advertise-client-urls http://${THIS_IP}:2379 --listen-client-urls http://${THIS_IP}:2379 \
	--initial-cluster ${CLUSTER} \
	--initial-cluster-state ${CLUSTER_STATE} --initial-cluster-token ${TOKEN}
```
### For machine 2
```
THIS_NAME=${NAME_2}
THIS_IP=${HOST_2}
etcd --data-dir=data.etcd --name ${THIS_NAME} \
	--initial-advertise-peer-urls http://${THIS_IP}:2380 --listen-peer-urls http://${THIS_IP}:2380 \
	--advertise-client-urls http://${THIS_IP}:2379 --listen-client-urls http://${THIS_IP}:2379 \
	--initial-cluster ${CLUSTER} \
	--initial-cluster-state ${CLUSTER_STATE} --initial-cluster-token ${TOKEN}
```
### For machine 3
```
THIS_NAME=${NAME_3}
THIS_IP=${HOST_3}
etcd --data-dir=data.etcd --name ${THIS_NAME} \
	--initial-advertise-peer-urls http://${THIS_IP}:2380 --listen-peer-urls http://${THIS_IP}:2380 \
	--advertise-client-urls http://${THIS_IP}:2379 --listen-client-urls http://${THIS_IP}:2379 \
	--initial-cluster ${CLUSTER} \
	--initial-cluster-state ${CLUSTER_STATE} --initial-cluster-token ${TOKEN}
```


### 查看etcd集群状态
```
export ETCDCTL_API=3
HOST_1=192.168.1.43
HOST_2=192.168.1.44
HOST_3=192.168.1.45
ENDPOINTS=$HOST_1:2379,$HOST_2:2379,$HOST_3:2379

etcdctl --endpoints=$ENDPOINTS member list
etcdctl  --endpoints=$ENDPOINTS endpoint health 
etcdctl --write-out=table --endpoints=$ENDPOINTS endpoint status
```
### ssl证书查看集群状态
```
ETCDCTL_ENDPOINTS=https://127.0.0.1:2379
ETCDCTL_CA_FILE=/etc/ssl/etcd/ssl/ca.pem
ETCDCTL_KEY_FILE=/etc/ssl/etcd/ssl/admin-node1-key.pem
ETCDCTL_CERT_FILE=/etc/ssl/etcd/ssl/admin-node1.pem


etcdctl --write-out=table --endpoints=$ETCDCTL_ENDPOINTS  --cacert=$ETCDCTL_CA_FILE \
--cert=$ETCDCTL_CERT_FILE \
--key=$ETCDCTL_KEY_FILE \
endpoint status
```


## systemcd启动方式部署集群
### 创建数据与配置目录
```
mkdir -p /var/lib/etcd
mkdir -p /etc/etcd
TOKEN=token-01
CLUSTER_STATE=new
NAME_1=etcd-1
NAME_2=etcd-2
NAME_3=etcd-3
HOST_1=192.168.1.43
HOST_2=192.168.1.44
HOST_3=192.168.1.45
CLUSTER=${NAME_1}=http://${HOST_1}:2380,${NAME_2}=http://${HOST_2}:2380,${NAME_3}=http://${HOST_3}:2380
```
### 下载etcd etcdctl 放在/usr/local/bin下。
```
ETCD_VER=v3.4.27

# choose either URL
GOOGLE_URL=https://storage.googleapis.com/etcd
GITHUB_URL=https://github.com/etcd-io/etcd/releases/download
DOWNLOAD_URL=${GOOGLE_URL}

rm -f /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
rm -rf /tmp/etcd-download-test && mkdir -p /tmp/etcd-download-test

curl -L ${DOWNLOAD_URL}/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz -o /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz -C /tmp/etcd-download-test --strip-components=1
rm -f /tmp/etcd-${ETCD_VER}-linux-amd64.tar.gz

/tmp/etcd-download-test/etcd --version
/tmp/etcd-download-test/etcdctl version
cp /tmp/etcd-download-test/etcd  /usr/local/bin/
cp /tmp/etcd-download-test/etcdctl /usr/local/bin/
```

### 配置etcd配置文件 machine 1
```
THIS_NAME=${NAME_1}
THIS_IP=${HOST_1}
cat >/etc/etcd/etcd.conf<<eof
ETCD_NAME=${NAME_1}
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://${THIS_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${THIS_IP}:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://${THIS_IP}:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${THIS_IP}:2380"
ETCD_INITIAL_CLUSTER_TOKEN=${TOKEN}
ETCD_INITIAL_CLUSTER="${CLUSTER}"
ETCD_INITIAL_CLUSTER_STATE=${CLUSTER_STATE}
eof
```
### 配置etcd配置文件 machine 2
```
THIS_NAME=${NAME_2}
THIS_IP=${HOST_2}
cat >/etc/etcd/etcd.conf<<eof
ETCD_NAME=${NAME_2}
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://${THIS_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${THIS_IP}:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://${THIS_IP}:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${THIS_IP}:2380"
ETCD_INITIAL_CLUSTER_TOKEN=${TOKEN}
ETCD_INITIAL_CLUSTER="${CLUSTER}"
ETCD_INITIAL_CLUSTER_STATE=${CLUSTER_STATE}
eof
```

### 配置etcd配置文件 machine 3
```
THIS_NAME=${NAME_3}
THIS_IP=${HOST_3}
cat >/etc/etcd/etcd.conf<<eof
ETCD_NAME=${NAME_3}
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://${THIS_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${THIS_IP}:2379"
ETCD_ADVERTISE_CLIENT_URLS="http://${THIS_IP}:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${THIS_IP}:2380"
ETCD_INITIAL_CLUSTER_TOKEN=${TOKEN}
ETCD_INITIAL_CLUSTER="${CLUSTER}"
ETCD_INITIAL_CLUSTER_STATE=${CLUSTER_STATE}
eof
```

### 配置systemd启动 (全部node配置)
```
source /etc/etcd/etcd.conf
cat >/usr/lib/systemd/system/etcd.service<<eof
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=/etc/etcd/etcd.conf
ExecStart=/usr/local/bin/etcd
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
eof
systemctl daemon-reload
systemctl restart etcd
systemctl status etcd
```


## 备份与恢复 snapshot  save | snapshot restore

### 备份 machine 1 其中一个节点(需要集群正常)
```
etcdctl --endpoints=${THIS_IP}:2379 snapshot save snapshot.db   
```
### 恢复 所有节点都需要执行
#### 节点machine 1
```
THIS_NAME=${NAME_1}
THIS_IP=${HOST_1}
source /etc/etcd/etcd.conf
etcdctl --endpoints=${THIS_IP}:2379 snapshot restore snapshot.db   --name $ETCD_NAME --initial-cluster $ETCD_INITIAL_CLUSTER  --initial-cluster-token $ETCD_INITIAL_CLUSTER_TOKEN --initial-advertise-peer-urls $ETCD_INITIAL_ADVERTISE_PEER_URLS --data-dir=$ETCD_DATA_DIR
systemctl restart etcd
```

#### 节点machine 2
```
THIS_NAME=${NAME_2}
THIS_IP=${HOST_2}
source /etc/etcd/etcd.conf
etcdctl --endpoints=${THIS_IP}:2379 snapshot restore snapshot.db   --name $ETCD_NAME --initial-cluster $ETCD_INITIAL_CLUSTER  --initial-cluster-token $ETCD_INITIAL_CLUSTER_TOKEN --initial-advertise-peer-urls $ETCD_INITIAL_ADVERTISE_PEER_URLS --data-dir=$ETCD_DATA_DIR
systemctl restart etcd
```

#### 节点machine 3
```
THIS_NAME=${NAME_3}
THIS_IP=${HOST_3}
source /etc/etcd/etcd.conf
etcdctl --endpoints=${THIS_IP}:2379 snapshot restore snapshot.db   --name $ETCD_NAME --initial-cluster $ETCD_INITIAL_CLUSTER  --initial-cluster-token $ETCD_INITIAL_CLUSTER_TOKEN --initial-advertise-peer-urls $ETCD_INITIAL_ADVERTISE_PEER_URLS --data-dir=$ETCD_DATA_DIR
systemctl restart etcd
```


### ssl 备份
```
 ETCDCTL_API=3 etcdctl --cacert=/opt/kubernetes/ssl/ca.pem --cert=/opt/kubernetes/ssl/server.pem --key=/opt/kubernetes/ssl/server-key.pem --endpoints=https://192.168.1.36:2379 snapshot save /data/etcd_backup_dir/etcd-snapshot-`date +%Y%m%d`.db
```


### ssl恢复备份

```bash
# k8s-master1 机器上操作
$ ETCDCTL_API=3 etcdctl snapshot restore /data/etcd_backup_dir/etcd-snapshot-20191222.db \
  --name etcd-0 \
  --initial-cluster "etcd-0=https://192.168.1.36:2380,etcd-1=https://192.168.1.37:2380,etcd-2=https://192.168.1.38:2380" \
  --initial-cluster-token etcd-cluster \
  --initial-advertise-peer-urls https://192.168.1.36:2380 \
  --data-dir=/var/lib/etcd/default.etcd
  
# k8s-master2 机器上操作
$ ETCDCTL_API=3 etcdctl snapshot restore /data/etcd_backup_dir/etcd-snapshot-20191222.db \
  --name etcd-1 \
  --initial-cluster "etcd-0=https://192.168.1.36:2380,etcd-1=https://192.168.1.37:2380,etcd-2=https://192.168.1.38:2380"  \
  --initial-cluster-token etcd-cluster \
  --initial-advertise-peer-urls https://192.168.1.37:2380 \
  --data-dir=/var/lib/etcd/default.etcd
  
# k8s-master3 机器上操作
$ ETCDCTL_API=3 etcdctl snapshot restore /data/etcd_backup_dir/etcd-snapshot-20191222.db \
  --name etcd-2 \
  --initial-cluster "etcd-0=https://192.168.1.36:2380,etcd-1=https://192.168.1.37:2380,etcd-2=https://192.168.1.38:2380"  \
  --initial-cluster-token etcd-cluster \
  --initial-advertise-peer-urls https://192.168.1.38:2380 \
  --data-dir=/var/lib/etcd/default.etcd
```

上面三台 ETCD 都恢复完成后，依次登陆三台机器启动 ETCD

```bash
$ systemctl start etcd
```

三台 ETCD 启动完成，检查 ETCD 集群状态

```bash
$ ETCDCTL_API=3 etcdctl --cacert=/opt/kubernetes/ssl/ca.pem --cert=/opt/kubernetes/ssl/server.pem --key=/opt/kubernetes/ssl/server-key.pem --endpoints=https://192.168.1.36:2379,https://192.168.1.37:2379,https://192.168.1.38:2379 endpoint health
```

三台 ETCD 全部健康，分别到每台 Master 启动 kube-apiserver

```bash
$ systemctl start kube-apiserver
```

检查 Kubernetes 集群是否恢复正常

```bash
$ kubectl get cs
```

## 总结

Kubernetes 集群备份主要是备份 ETCD 集群。而恢复时，主要考虑恢复整个顺序：

`停止kube-apiserver --> 停止ETCD --> 恢复数据 --> 启动ETCD --> 启动kube-apiserve`
