# 单节点 K8s 证书轮换(测试 / 验证脚本用)

> **定位**:这份文档**仅用于在单 master 测试集群上跑通流程、调试脚本**。
> 生产环境 3 master 请走 [k8s-cert-rotation-3masters.md](k8s-cert-rotation-3masters.md),不要混用。
> 配套脚本:[k8s-cert-rotation-single.sh](k8s-cert-rotation-single.sh)。

## 一、用这篇文档干什么

| 场景 | 用本篇 |
|---|---|
| 在测试环境验证新写的脚本逻辑(timeout、轮询、备份路径) | ✅ |
| 学习 / 演练证书轮换流程,建立肌肉记忆 | ✅ |
| 边缘 / 单点 lab 集群临时续命 | ✅ |
| **生产 3 master HA 集群** | ❌ 用 [3masters.md](k8s-cert-rotation-3masters.md) |
| **生产单 master 业务集群** | ❌ 优先扩 HA,见 [../kubeadm/kubeadm-ha-cluster.md](../kubeadm/kubeadm-ha-cluster.md) |

## 二、跟 3 节点版的差异(只列不同)

| 维度 | 3 master | 单 master(本篇) |
|---|---|---|
| 三台之间串行 | 必须 | **没有这步,一次跑完** |
| etcd 健康判定 | `--cluster` 看 3/3 healthy | 看 1/1 healthy(去掉 `--cluster`) |
| apiserver 重启影响 | LB 切走,业务无感 | **整个控制面停 30~120s**,kubectl 报错、不调度 |
| 数据面(业务 Pod) | 不受影响 | **同样不受影响**(kubelet/runtime 没动) |
| 备份重要性 | 重要 | **极其重要,没有冗余可以救你** |
| 回滚 | 单台坏可切流量 | 坏了就是整个集群停摆,**必须验过 etcd snapshot** |
| 操作时长 | 1~2 小时 | 15 分钟 |
| 维护窗口预留 | 1 小时 | **至少 1 小时**(给意外留余量,不是按"应该多久"算) |

## 三、完整流程

### 3.1 前置检查

```bash
# 1) 确认是单 master
kubectl get node -l node-role.kubernetes.io/control-plane
# 期望:只看到 1 行

# 2) 确认 stacked etcd
ls /etc/kubernetes/manifests/etcd.yaml

# 3) 当前证书过期时间(留底)
kubeadm certs check-expiration
```

### 3.2 备份(单节点这一步比 3 节点更重要)

```bash
TS=$(date +%F-%H%M)
BAK=/root/cert-rotate-${TS}
mkdir -p ${BAK}

# 整目录备份
cp -a /etc/kubernetes ${BAK}/etc-kubernetes
ls ${BAK}/etc-kubernetes/      # 应看到 pki/ manifests/ admin.conf

# etcd 快照
export ETCDCTL_API=3
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save ${BAK}/etcd-snapshot.db

# 校验快照(**单节点必须验,没有冗余**)
etcdctl --write-out=table snapshot status ${BAK}/etcd-snapshot.db
# 期望:看到 HASH / REVISION / TOTAL KEYS / TOTAL SIZE,DB SIZE 不能是 0

ls -lh ${BAK}/
```

### 3.3 续证书 + 校验 + 更新 kubeconfig

```bash
kubeadm certs renew all
kubeadm certs check-expiration                       # 非 CA 行都应该是 1 年后
cp -f /etc/kubernetes/admin.conf /root/.kube/config
```

### 3.4 重启 4 个 static pod

跟 3 节点完全一样的轮询逻辑,但 etcd 健康检查从 3/3 改成 1/1:

```bash
cd /etc/kubernetes/manifests

wait_container_gone() {
    local name=$1 max=${2:-60} i=0
    while crictl ps -q --name "$name" 2>/dev/null | grep -q .; do
        i=$((i+1))
        [ $i -ge $max ] && { echo "  [TIMEOUT] $name 没停"; return 1; }
        printf "\r  [%02ds] 等待 %s 停止..." $i "$name"; sleep 1
    done
    printf "\r  [%02ds] %s 已停止     \n" $i "$name"
}
wait_container_up() {
    local name=$1 max=${2:-90} i=0
    while ! crictl ps --name "$name" 2>/dev/null | grep -q Running; do
        i=$((i+1))
        [ $i -ge $max ] && { echo "  [TIMEOUT] $name 没起来"; return 1; }
        printf "\r  [%02ds] 等待 %s 拉起..." $i "$name"; sleep 1
    done
    printf "\r  [%02ds] %s Running    \n" $i "$name"
}
# 单节点版:只看本机 etcd 1/1 healthy
wait_etcd_single_healthy() {
    local max=${1:-180} i=0
    while true; do
        if ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
              --cacert=/etc/kubernetes/pki/etcd/ca.crt \
              --cert=/etc/kubernetes/pki/etcd/server.crt \
              --key=/etc/kubernetes/pki/etcd/server.key \
              endpoint health 2>&1 | grep -q "is healthy"; then
            printf "\r  [%02ds] etcd 1/1 healthy ✓    \n" $i
            return 0
        fi
        i=$((i+1))
        [ $i -ge $max ] && { echo "  [TIMEOUT] etcd ${max}s 没恢复"; return 1; }
        printf "\r  [%02ds] 等 etcd 启动..." $i; sleep 1
    done
}

for f in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml; do
    name=$(basename $f .yaml | sed 's/^kube-//')
    [ "$name" = "etcd" ] && UP_TIMEOUT=180 || UP_TIMEOUT=90
    echo ""
    echo "==== [$(date +%T)] 处理 $f ===="
    mv $f /tmp/$f
    wait_container_gone "$name" 60 || break
    mv /tmp/$f .
    wait_container_up "$name" $UP_TIMEOUT || break
    sleep 5
    crictl ps --name "$name" | grep -v CONTAINER || { echo "[FAIL] $name 又掉了"; break; }
    [ "$name" = "etcd" ] && { wait_etcd_single_healthy 180 || break; }
    echo "  ✓ $f 完成"
done
```

> **注意**:单节点跑这段时,**这台机器上的 kubectl 会有 30~120s 报错**(apiserver 自己重启自己)。
> 用 `crictl ps` 直接看容器状态,不要依赖 kubectl。

### 3.5 重启 kubelet

```bash
systemctl restart kubelet
systemctl status kubelet --no-pager | head -10
```

## 四、验证(单节点版)

```bash
NODE=$(hostname)

# 1) 节点 Ready
kubectl get node $NODE
# 期望:STATUS = Ready

# 2) 4 个控制面 pod(单节点各 1 个)
kubectl get pod -n kube-system -o wide --field-selector spec.nodeName=$NODE \
  | grep -E 'apiserver|controller-manager|scheduler|etcd'
# 期望:4 个 Running 1/1,RESTARTS 比之前 +1

# 3) etcd 单节点健康
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status -w table
# 期望:1 行,IS LEADER = true,ERRORS 为空

# 4) 读写探活
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  put cert-rotate-test "$(date)" && \
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  del cert-rotate-test

# 5) apiserver readyz
kubectl get --raw='/readyz?verbose' | tail -10

# 6) 新证书从端口取(不是磁盘)
echo | openssl s_client -connect 127.0.0.1:6443 -servername kubernetes 2>/dev/null \
  | openssl x509 -noout -dates
echo | openssl s_client -connect 127.0.0.1:2379 2>/dev/null \
  | openssl x509 -noout -dates
echo | openssl s_client -connect 127.0.0.1:2380 2>/dev/null \
  | openssl x509 -noout -dates
# 期望:三个 notAfter 都是 1 年后

# 7) 业务 Pod 没受影响
kubectl get pod -A | grep -vE 'Running|Completed'
# 期望:输出只有表头
```

## 五、回滚(单节点关键路径)

### 5.1 控制面起不来但 etcd 没坏

```bash
TS=<备份时间戳>
BAK=/root/cert-rotate-${TS}
mv /etc/kubernetes /etc/kubernetes.broken.$(date +%s)
cp -a ${BAK}/etc-kubernetes /etc/kubernetes
cp -f /etc/kubernetes/admin.conf /root/.kube/config
# 触发 static pod 重建
cd /etc/kubernetes/manifests
for f in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml; do
    mv $f /tmp/$f; sleep 5; mv /tmp/$f .; sleep 10
done
systemctl restart kubelet
```

### 5.2 etcd 数据损坏(最坏情况)

```bash
# 1) 停 etcd static pod
mv /etc/kubernetes/manifests/etcd.yaml /tmp/
sleep 10
crictl ps --name etcd     # 应该空

# 2) 移走旧数据
mv /var/lib/etcd /var/lib/etcd.broken.$(date +%s)

# 3) 从 snapshot 恢复
ETCDCTL_API=3 etcdctl snapshot restore ${BAK}/etcd-snapshot.db \
  --data-dir=/var/lib/etcd \
  --name=$(grep -- '--name=' /tmp/etcd.yaml | head -1 | sed 's/.*--name=//' | awk '{print $1}') \
  --initial-advertise-peer-urls=https://$(hostname -i):2380 \
  --initial-cluster=$(hostname)=https://$(hostname -i):2380

# 4) 拉回 etcd static pod
mv /tmp/etcd.yaml /etc/kubernetes/manifests/
sleep 15
crictl ps --name etcd     # 应该 Running
```

## 六、从单机经验迁移到 3 节点要注意什么

测试单节点跑通后,搬到 3 节点生产时**这几个地方不能照抄**:

| 单节点这样做 | 3 节点要改成 |
|---|---|
| 4 个 pod 重启循环一把跑完 | 一样,但**每台 master 独立跑一次**,中间等 5 分钟 |
| etcd 健康检查 `endpoint health` | 改成 `endpoint health --cluster`,等 3/3 healthy |
| 验证步骤里 kubectl get pod 期望 4 个 | 期望 4×3=12 个 |
| `--initial-cluster` 只有自己 | 恢复 etcd 时**绝不能直接抄单节点恢复命令**,3 节点恢复要包含全部 3 个成员,而且要 3 台都同步执行;详见 [../etcd/etcd-restore.sh](../etcd/etcd-restore.sh) |
| 维护窗口"低峰 15 分钟" | 改成"低峰 1~2 小时",必须串行 master-1 → master-2 → master-3 |

## 七、常见坑(单节点特有)

| 现象 | 原因 | 处理 |
|---|---|---|
| 重启 apiserver 期间 kubectl 全报错 | 单节点没 HA | 正常现象,等 30~120s,**用 crictl 看容器状态** |
| etcd 重启后 `endpoint health` 一直 unhealthy | WAL 回放慢 / 磁盘 IO 卡 | 等到 3 分钟还不行,看 `crictl logs $(crictl ps -q --name etcd)` |
| `--name=` 取不到值 | etcd.yaml 已经被 mv 走 | 恢复前先记下来:`grep '\-\-name=' /etc/kubernetes/manifests/etcd.yaml` |
| 重启后 coredns 全部 CrashLoopBackOff | apiserver 还没完全 ready,coredns 连不上 | 等 2 分钟自愈;不愈则 `kubectl rollout restart deploy/coredns -n kube-system` |
