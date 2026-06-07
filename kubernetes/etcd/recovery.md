# etcd 3 节点集群恢复实录

## 结论先行

恢复分三步：

```
1. 选一个节点从 snapshot 恢复
2. 验证数据
3. 其他节点重新加入
```

> 不要想着把三个节点全都原地复活。拿出一个干净的 snapshot，重建种子节点，剩下的重新加入就行。越快越好，别在坏数据上纠结。

## 用旧 CA 重建整个集群（推荐做法）

### 原理

只要 CA（ca.crt + ca.key）没变，集群就是一个整体。master 可以重做，worker 不用动，因为它们之间的信任关系由 CA 维系。

```
ca.crt + ca.key = 集群身份证的根
↓
用旧 ca init → 新 apiserver 的证书是旧根签的
               worker 的 kubelet 证书也是旧根签的
               → 互相认识，不用重新 join
↓
etcd snapshot → 恢复所有资源对象
               → 恢复后的集群就是换了个机器，东西一样
```

### 需要什么

```
· 旧的 /etc/kubernetes/pki/ 完整备份（必需）
· etcd snapshot（数据源）
· kubeadm 配置文件（--control-plane-endpoint 等参数）
```

### 操作步骤

#### 1. 新机器上放旧 pki

```bash
# 把备份的 pki 目录放到新机器
scp -r backup/pki new-master:/etc/kubernetes/pki

# 确认 ca.crt + ca.key 都在
ls /etc/kubernetes/pki/ca.*
```

#### 2. kubeadm init 重建 master

kubeadm 检测到已有 ca.crt 就不会重新生成，沿用旧的信任体系。

```bash
kubeadm init --control-plane-endpoint=172.16.0.10:6443 \
  --pod-network-cidr=10.244.0.0/16 \
  --upload-certs
```

用了旧 ca，init 之后 apiserver、etcd 等组件的证书也是旧根重新签发的。根一样，集群内通信就没问题。

#### 3. 停止 etcd static pod

```bash
# 把 manifests 移走，kubelet 自动停掉 etcd 容器
mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sleep 30  # 等容器完全退出
```

#### 4. 恢复 etcd snapshot

```bash
# 备份刚 init 产生的空 etcd 数据
mv /var/lib/etcd /var/lib/etcd.empty

# 从 snapshot 恢复
etcdctl snapshot restore /backup/etcd-snap.db \
  --data-dir=/var/lib/etcd \
  --name=master1 \
  --initial-cluster=master1=https://172.16.150.128:2380 \
  --initial-cluster-token=etcd-cluster \
  --initial-advertise-peer-urls=https://172.16.150.128:2380
```

#### 5. 重启 etcd

```bash
# manifests 放回去，kubelet 自动拉起 etcd
mv /tmp/etcd.yaml /etc/kubernetes/manifests/
sleep 30

# 确认数据回来了
kubectl get nodes
kubectl get pods -A
```

#### 6. 其他 master 重新加入

```bash
kubeadm join 172.16.0.10:6443 --control-plane \
  --token *** \
  --discovery-token-ca-cert-hash sha256:<hash>

# token 和 hash 从第一步 init 的输出里拿
# 或者用 kubeadm token create --print-join-command 生成
```

#### 7. worker 节点

**不需要任何操作。** CA 没变，kubelet 证书还是旧的根签的，几秒钟后自动重新连上 API server。如果一直没恢复，重启一下 kubelet 即可：

```bash
systemctl restart kubelet   # 大多时候不需要，保险做法
kubectl get nodes           # 等一小会儿，worker 应该全回来了
```

### 要点

```
· pki 目录必须单独备份，比 etcd snapshot 还重要
· pki 在 → worker 不用动，几秒钟自动恢复
· pki 丢 → worker 全部 kubeadm reset + 重新 join
· 重建时 admin.conf 默认走 LB，注意前面说的指向风险
```

## 3 节点 etcd 原地恢复（单独 etcd 集群损坏）

### 步骤

```
1. 所有 etcd 节点停掉
2. 挑一个节点用 snapshot 恢复
   etcdctl snapshot restore /backup/snap.db --data-dir=/var/lib/etcd
3. 验证恢复后的节点能正常启动
   etcdctl endpoint health
   etcdctl get / --prefix --keys-only | head -10
4. 其他节点不复制数据目录，直接当新节点重新加入集群
5. member 加进来后，数据自动从恢复好的节点同步
```

### 为什么这么干

三个节点的数据目录已经不一致了，直接复制会带错数据。从 snapshot 重建一个种子节点，再让其他节点重新同步，是最干净的方式。
