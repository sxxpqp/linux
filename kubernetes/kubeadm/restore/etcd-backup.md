# etcd 通过 snap.db 快照恢复到 k8sm1 单节点

## 前提条件
- 已有 snap.db 快照文件
- k8sm1 节点 IP: 192.168.100.10

## 步骤 1: 停止 etcd

```bash
# 停止 etcd (如果使用 systemd)
systemctl stop etcd

# 或者删除 static pod manifest 让 kubelet 停止它
mv /etc/kubernetes/manifests/etcd.yaml /tmp/
```

## 步骤 2: 备份当前数据（可选但推荐）

```bash
mv /var/lib/etcd /var/lib/etcd.backup.$(date +%Y%m%d%H%M%S)
```

## 步骤 3: 通过 snap.db 恢复数据

```bash
# 确保 snap.db 文件位置，假设在 /tmp/snap.db
# 恢复数据到 /var/lib/etcd

etcdutl snapshot restore /tmp/snap.db \
  --data-dir=/var/lib/etcd \
  --name=k8sm1.sohuglobal \
  --initial-cluster=k8sm1.sohuglobal=https://192.168.100.10:2380 \
  --initial-advertise-peer-urls=https://192.168.100.10:2380
```

## 步骤 4: 设置正确的权限

```bash
chown -R etcd:etcd /var/lib/etcd
# 或者如果使用 root 运行
chown -R root:root /var/lib/etcd
```

## 步骤 5: 更新 etcd 配置文件

修改 `/etc/kubernetes/manifests/etcd.yaml`，确保配置如下：

```yaml
spec:
  containers:
  - name: etcd
    command:
    - etcd
    - --name=k8sm1.sohuglobal
    - --data-dir=/var/lib/etcd
    - --initial-cluster=k8sm1.sohuglobal=https://192.168.100.10:2380
    - --initial-cluster-state=new  # 第一次启动用 new，成功后重启改为 existing 还原启动应该设置为 existing。
    - --advertise-client-urls=https://192.168.100.10:2379
    - --client-urls=https://192.168.100.10:2379
    - --listen-client-urls=https://0.0.0.0:2379
    - --listen-peer-urls=https://0.0.0.0:2380
    - --peer-urls=https://192.168.100.10:2380
    - --initial-advertise-peer-urls=https://192.168.100.10:2380
    - --cert-file=/etc/kubernetes/pki/etcd/server.crt
    - --key-file=/etc/kubernetes/pki/etcd/server.key
    - --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
    - --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
    - --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
    - --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```

> **注意：** 第一次启动使用 `--initial-cluster-state=new`，etcd 启动成功后，如果后续需要重启 etcd，应将此参数改为 `existing` 或直接删除该参数。

## 步骤 6: 启动 etcd

```bash
# 如果使用 static pod，将 manifest 移回
mv /tmp/etcd.yaml /etc/kubernetes/manifests/

# 检查 etcd 是否启动
kubectl get pods -n kube-system | grep etcd

# 或者查看日志
crictl logs $(crictl ps -q --name etcd)
```

## 步骤 7: 验证集群状态

```bash
export ETCDCTL_API=3

# 检查集群健康
etcdctl --endpoints=https://192.168.100.10:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health

# 检查成员列表
etcdctl --endpoints=https://192.168.100.10:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list

# 检查数据库状态
etcdctl --endpoints=https://192.168.100.10:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status
```

---

## 原恢复方案（添加 k8sm2/k8sm3 节点）

### 步骤 1: 确认 k8sm1 集群状态
首先在 k8sm1 上检查集群状态：


export ETCDCTL_API=3
etcdctl --endpoints=https://192.168.100.10:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member list
步骤 2: 添加 k8sm2 为新成员 
k8sm2配置
- --initial-cluster=k8sm2.sohuglobal=https://192.168.100.30:2380,k8sm1.sohuglobal=https://192.168.100.10:2380
- --initial-cluster-state=existing
/var/lib/etcd/  为空


在 k8sm1 上执行：


etcdctl --endpoints=https://192.168.100.10:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member add k8sm2.sohuglobal --peer-urls=https://192.168.100.30:2380
步骤 3: 添加 k8sm3 为新成员
k8sm3配置
    - --initial-cluster=k8sm2.sohuglobal=https://192.168.100.30:2380,k8sm1.sohuglobal=https://192.168.100.10:2380,k8sm3.sohuglobal=https://192.168.100.21:2380
    - --initial-cluster-state=existing
在 k8sm1 上执行：


etcdctl --endpoints=https://192.168.100.10:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  member add k8sm3.sohuglobal --peer-urls=https://192.168.100.21:2380


  
步骤 4: 更新 k8sm1 的 etcd 配置
修改 /etc/kubernetes/manifests/etcd.yaml，更新 --initial-cluster 参数：


- --initial-cluster=k8sm1.sohuglobal=https://192.168.100.10:2380,k8sm2.sohuglobal=https://192.168.100.30:2380,k8sm3.sohuglobal=https://192.168.100.21:2380
- --initial-cluster-state=existing  # 从 new 改为 existing
步骤 5: 配置 k8sm2 的 etcd
修改 /etc/kubernetes/manifests/etcd.yaml：


- --initial-cluster=k8sm1.sohuglobal=https://192.168.100.10:2380,k8sm2.sohuglobal=https://192.168.100.30:2380,k8sm3.sohuglobal=https://192.168.100.21:2380
- --initial-cluster-state=existing
- --name=k8sm2.sohuglobal
确保 /var/lib/etcd 目录是空的或者删除后重建。

步骤 6: 配置 k8sm3 的 etcd
修改 /etc/kubernetes/manifests/etcd.yaml：


- --initial-cluster=k8sm1.sohuglobal=https://192.168.100.10:2380,k8sm2.sohuglobal=https://192.168.100.30:2380,k8sm3.sohuglobal=https://192.168.100.21:2380
- --initial-cluster-state=existing
- --name=k8sm3.sohuglobal
确保 /var/lib/etcd 目录是空的。

步骤 7: 重启各节点 etcd
在每个节点上：


# 方法 1: 删除静态 Pod manifest 让 kubelet 重建
mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sleep 5
mv /tmp/etcd.yaml /etc/kubernetes/manifests/

关键注意事项
证书问题: k8sm2 和 k8sm3 需要有正确的 etcd 证书（server.crt, server.key, peer.crt, peer.key, ca.crt）

数据目录: k8sm2 和 k8sm3 的 /var/lib/etcd 必须是空的，因为它们将作为新成员从集群同步数据

顺序很重要: 必须先通过 member add 添加成员，然后再启动新节点的 etcd




ETCDCTL_API=3 etcdctl --endpoints=https://192.168.100.10:2379,https://192.168.100.21:2379,https://192.168.100.30:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key member list && ETCDCTL_API=3 etcdctl --endpoints=https://192.168.100.10:2379,https://192.168.100.21:2379,https://192.168.100.30:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint health && ETCDCTL_API=3 etcdctl --endpoints=https://192.168.100.10:2379,https://192.168.100.21:2379,https://192.168.100.30:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key endpoint status -w table
