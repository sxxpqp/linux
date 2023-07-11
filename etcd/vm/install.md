### 主机名与ip对应关系
```
主机名  ip
etcd1   192.168.1.43
etcd2   192.168.1.44 
etcd3   192.168.1.45
```

### 2.2.2. 安装etcd
```
yum install etcd -y
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
etcdctl cluster-health
```





