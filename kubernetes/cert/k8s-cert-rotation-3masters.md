# 3 节点 K8s 集群证书轮换（生产环境)

> 适用:kubeadm 部署的 3 master HA 集群(etcd stacked,即 etcd 和 apiserver 跑在同一台),证书快过期或已过期需要续签。
> 参考脚本:[k8s-cert-rotation.sh](k8s-cert-rotation.sh)。本篇是**带验证步骤**的生产操作手册。

## 一、原理与影响范围

### 1.1 kubeadm 管理的证书

`kubeadm certs renew all` 会更新 `/etc/kubernetes/pki/` 下这一组证书,默认有效期 **1 年**:

| 证书 | 用途 |
|---|---|
| `apiserver.crt` | kube-apiserver 对外服务证书 |
| `apiserver-kubelet-client.crt` | apiserver 访问 kubelet |
| `apiserver-etcd-client.crt` | apiserver 访问 etcd |
| `front-proxy-client.crt` | 聚合层 |
| `etcd/server.crt` / `etcd/peer.crt` | etcd server / peer |
| `etcd/healthcheck-client.crt` | etcd 健康检查 |
| `controller-manager.conf` / `scheduler.conf` / `admin.conf` / `super-admin.conf` 里嵌的证书 | 控制面 kubeconfig |

### 1.2 不在本次操作范围内的

| 项 | 说明 |
|---|---|
| **CA 根证书**(`ca.crt` / `etcd/ca.crt` / `front-proxy-ca.crt`) | 默认有效期 10 年,**本次不动**。如果 CA 也快过期,操作复杂度完全不一样,需要单独流程(本篇不覆盖) |
| **kubelet 客户端证书**(`/var/lib/kubelet/pki/kubelet-client-*.pem`) | 默认开启自动轮换(`rotateCertificates: true`),不需要手动续。本篇会顺手验证一下 |
| **kubelet 服务端证书**(`/var/lib/kubelet/pki/kubelet.crt` 或轮换后的 `kubelet-server-*.pem`) | 同上,通常自动轮换 |
| **业务证书**(Ingress / cert-manager / 自签 webhook) | 跟 kubeadm 无关,独立续 |

### 1.3 业务影响

- **apiserver 短暂不可用**:每台 master 重建 static pod 时,本机 apiserver 会断 30~60s。前面有 LB / kube-vip 时,客户端会自动切到其它两台,**业务流量基本无感**。
- **etcd 短暂少一个成员**:stacked etcd 重建时,3 节点 etcd 会变成 2/3 健康,只要不并行操作,quorum 不丢。
- **kubectl 命令可能短暂报错**:如果你 kubeconfig 指的就是正在重建的那台,执行命令会超时,切到另一台 master 操作即可。
- **业务 Pod 不重启**:kubelet 的容器运行时不受 apiserver 短暂中断影响,已运行的 Pod 不会重启。

> 因此**必须串行操作**,master-1 完全恢复后再动 master-2,以此类推。

---

## 二、前置准备(在任一 master 上做)

### 2.0 主机上装好 etcdctl(kubeadm 默认不装)

kubeadm 部署的集群 etcd 是 static pod,etcdctl 只在容器里,**主机上 `command -v etcdctl` 会找不到**。
本流程的备份 / 验证步骤都要在主机直接用 etcdctl,先在**所有 master** 上装好:

```bash
# 仓库里现成的(chfs 拉,30 秒搞定)
wget https://chfs.sxxpqp.top:8443/chfs/shared/k8s/etcd/etcd-v3.5.18-linux-amd64.tar.gz
tar -xzf etcd-v3.5.18-linux-amd64.tar.gz -C /usr/local/bin/ --strip-components=1 etcd-v3.5.18-linux-amd64/etcdctl
etcdctl version
# 或:bash kubernetes/etcd/instatletcdctl.sh
```

> 版本对齐:etcdctl 版本应**等于或新于**集群 etcd 版本。查集群 etcd 版本:`crictl exec $(crictl ps -q --name etcd | head -1) etcd --version`

### 2.1 收集集群基本信息

```bash
# 1) 3 个 master 节点名 / IP
kubectl get node -o wide -l node-role.kubernetes.io/control-plane
# 预期:看到 3 行 Ready 的 master,记下 NAME / INTERNAL-IP

# 2) K8s 版本(后面要对得上)
kubeadm version -o short
kubectl version --short 2>/dev/null || kubectl version

# 3) etcd 拓扑(stacked or external)
ls /etc/kubernetes/manifests/etcd.yaml 2>&1
# 有这个文件 → stacked(本篇覆盖)
# 没有 → external etcd,etcd 证书续签流程不一样,本篇不适用

# 4) VIP / LB 入口(确认前端有高可用)
grep server /etc/kubernetes/admin.conf
# 正常应该是 VIP 或 LB 域名,不是单台 master IP
```

### 2.2 查看当前证书过期时间(关键)

**在 3 台 master 上分别执行**:

```bash
kubeadm certs check-expiration
```

期望输出关注两段:
- 上半段:`apiserver` / `apiserver-kubelet-client` / `apiserver-etcd-client` / `controller-manager.conf` / `scheduler.conf` / `admin.conf` / `etcd-server` / `etcd-peer` / `etcd-healthcheck-client` / `front-proxy-client` —— **这些是要轮换的**
- 下半段 `CERTIFICATE AUTHORITY`:`ca` / `etcd-ca` / `front-proxy-ca` —— 这些**不能过期**,如果剩余时间 < 1 年,本篇流程不够用,需要先续 CA。

把每台输出存档:

```bash
mkdir -p /root/cert-rotate-$(date +%F)
kubeadm certs check-expiration > /root/cert-rotate-$(date +%F)/before-$(hostname).txt
```

### 2.3 备份(强烈建议,出问题这是救命的)

**3 台 master 都做**:

**推荐:整目录备份 + etcd 快照,一把梭,漏不掉东西**

```bash
TS=$(date +%F-%H%M)
BAK=/root/cert-rotate-${TS}
mkdir -p ${BAK}

# 1) 整个 /etc/kubernetes(pki/ + manifests/ + 所有 *.conf 全在里面)
cp -a /etc/kubernetes ${BAK}/etc-kubernetes
ls ${BAK}/etc-kubernetes/       # 应看到 pki/ manifests/ admin.conf 等

# 2) /root/.kube/config(管理员 kubeconfig,跟 admin.conf 一份内容,留个底)
cp /root/.kube/config ${BAK}/root-kube-config 2>/dev/null || true

# 3) etcd 快照(stacked etcd 在每台 master 都跑;external etcd 在 etcd 节点跑)
export ETCDCTL_API=3
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save ${BAK}/etcd-snapshot.db

# 4) 必须校验,不然损坏的快照恢复不了
etcdctl --write-out=table snapshot status ${BAK}/etcd-snapshot.db
# 期望:HASH / REVISION / TOTAL KEYS / TOTAL SIZE 四列;文件不能是 0 字节
ls -lh ${BAK}/
```

> 为什么用 `cp -a` 一把梭而不是分项 cp:
> - `-a` = 保留权限/属主/时间戳/软链接,出问题 `rm -rf /etc/kubernetes && cp -a ${BAK}/etc-kubernetes /etc/kubernetes` 就能整体回滚。
> - 分项 cp(pki / *.conf / manifests)容易漏掉以后版本里新加的东西(比如 1.29 加的 `super-admin.conf`、`pki/etcd/` 子目录里的某些文件)。

### 2.4 记录当前集群健康基线(后面对比用)

**在任一台健康 master 上**:

```bash
BASE=/root/cert-rotate-$(date +%F)
mkdir -p $BASE
kubectl get node -o wide                          > $BASE/baseline-nodes.txt
kubectl get pod -A -o wide                        > $BASE/baseline-pods.txt
kubectl get cs                                    > $BASE/baseline-cs.txt 2>&1
kubectl get --raw='/readyz?verbose'               > $BASE/baseline-readyz.txt 2>&1
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table              > $BASE/baseline-etcd.txt
```

---

## 三、master-1 操作步骤(完整,master-2/3 重复)

> 假定 3 台 master 节点名:`master-1` / `master-2` / `master-3`。
> **操作位置**:登录 `master-1`,以下所有命令在 `master-1` 上执行;验证命令可以从任意健康节点跑。

### 3.1 续签证书

```bash
kubeadm certs renew all
```

期望输出:每一项后面都是 `certificate renewed`,**没有 ERROR**。

> 注:这一步只是写新文件到 `/etc/kubernetes/pki/`,**正在运行的 apiserver / etcd / cm / scheduler 还在用内存里的旧证书**,所以业务此刻完全不受影响。

### 3.2 校验新证书已落盘

```bash
kubeadm certs check-expiration
```

期望:除了 `*-ca` 三行,**其它所有行的 Residual Time 都变成接近 1 年**(`364d` 左右)。

### 3.3 更新管理员 kubeconfig

```bash
cp -f /etc/kubernetes/admin.conf /root/.kube/config
# 如果普通用户也用 kubectl,也要同步
# cp -f /etc/kubernetes/admin.conf /home/<user>/.kube/config && chown <user>: /home/<user>/.kube/config
```

### 3.4 逐个重启控制面 static pod

> **关键**:逐个重启,**不是一次性全部 move 走**。一次性 move 走 4 个 yaml 会让整台 master 失能,etcd 也会短暂掉一个成员,如果同时 master-2/3 有问题就直接丢 quorum。

**不要用死 sleep**,用轮询 + 实时进度输出,避免干等还看不到状态。把下面这段贴进 master 当前 shell 直接跑:

```bash
cd /etc/kubernetes/manifests

# 工具函数:轮询等容器消失 / 出现,每秒打一行进度
wait_container_gone() {        # $1=容器名关键字  $2=最长等待秒(默认 60)
    local name=$1 max=${2:-60} i=0
    while crictl ps -q --name "$name" 2>/dev/null | grep -q .; do
        i=$((i+1))
        [ $i -ge $max ] && { echo "  [TIMEOUT] $name 容器 ${max}s 内没停"; return 1; }
        printf "\r  [%02ds] 等待 %s 容器停止..." $i "$name"; sleep 1
    done
    printf "\r  [%02ds] %s 容器已停止     \n" $i "$name"
}
wait_container_up() {          # $1=容器名关键字  $2=最长等待秒(默认 90)
    local name=$1 max=${2:-90} i=0
    while ! crictl ps --name "$name" 2>/dev/null | grep -q Running; do
        i=$((i+1))
        [ $i -ge $max ] && { echo "  [TIMEOUT] $name 容器 ${max}s 内没起来"; return 1; }
        printf "\r  [%02ds] 等待 %s 容器拉起..." $i "$name"; sleep 1
    done
    printf "\r  [%02ds] %s 容器 Running   \n" $i "$name"
}

for f in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml; do
    name=$(basename $f .yaml | sed 's/^kube-//')
    echo ""
    echo "==== [$(date +%T)] 处理 $f ===="
    echo "  [1/4] 移走 manifest → 等 kubelet 停旧 pod"
    mv $f /tmp/$f
    wait_container_gone "$name" 60 || break

    echo "  [2/4] 移回 manifest → 等 kubelet 拉起新 pod(加载新证书)"
    mv /tmp/$f .
    wait_container_up "$name" 120 || break

    echo "  [3/4] 多观察 5s,确保不是起来又挂"
    sleep 5
    crictl ps --name "$name" | grep -v CONTAINER || { echo "  [FAIL] $name 又掉了"; break; }

    echo "  [4/4] $f 完成 ✓"
done
echo ""
echo "==== [$(date +%T)] 控制面 4 个 static pod 全部重建完成 ===="
```

**预期输出样子**(每个组件一段,有可见进度):

```
==== [14:32:10] 处理 kube-apiserver.yaml ====
  [1/4] 移走 manifest → 等 kubelet 停旧 pod
  [03s] apiserver 容器已停止
  [2/4] 移回 manifest → 等 kubelet 拉起新 pod(加载新证书)
  [12s] apiserver 容器 Running
  [3/4] 多观察 5s,确保不是起来又挂
  [4/4] kube-apiserver.yaml 完成 ✓
```

**如果某个组件在新窗口里再观察**(可选,另开一个 SSH 窗口):

```bash
watch -n 1 'crictl ps --name "kube-apiserver|controller|scheduler|etcd"; echo; \
            kubectl get pod -n kube-system --field-selector spec.nodeName=$(hostname) 2>&1 | tail -10'
```

### 3.5 重启 kubelet

让 kubelet 重新加载 `/etc/kubernetes/kubelet.conf`(里面引用的客户端证书也被 `renew all` 更新了):

```bash
systemctl restart kubelet
systemctl status kubelet --no-pager | head -20
```

期望:`active (running)`,日志里没有 `x509` / `certificate` 报错。

### 3.6 master-1 单机验证(必须全绿才动 master-2)

**全部从 master-1 上跑**(也可以从其它健康 master 上跑,只要 kubeconfig 指向 VIP):

```bash
# 1) 本节点 Ready
kubectl get node master-1
# 期望:STATUS = Ready

# 2) 本节点上的 4 个控制面 Pod 都 Running 且 Ready 1/1
kubectl get pod -n kube-system -o wide --field-selector spec.nodeName=master-1 \
  | grep -E 'apiserver|controller-manager|scheduler|etcd'
# 期望:全部 Running 1/1,RESTARTS 比之前 +1

# 3) etcd 集群 quorum 健康
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table
# 期望:3 行,IS LEADER 有且只有一个,ERRORS 列全空

ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health --cluster
# 期望:3 行全部 "is healthy"

# 4) apiserver 健康端点
kubectl get --raw='/readyz?verbose' | tail -20
# 期望:最后一行 "readyz check passed"

# 5) 新证书真的生效了(从 TCP 端口读 cert,而不是从磁盘)
echo | openssl s_client -connect 127.0.0.1:6443 -servername kubernetes 2>/dev/null \
  | openssl x509 -noout -dates -subject
# 期望:notAfter 是 1 年后的日期

# 6) 简单的功能验证
kubectl get ns
kubectl auth can-i '*' '*' --all-namespaces
```

**任一项不符合预期,立即停止,不要动 master-2/3,跳到第六节"回滚"。**

### 3.7 等待 5~10 分钟观察

- `kubectl get pod -A` 看有没有异常 Pod 在 Pending / CrashLoopBackOff
- `kubectl get event -A --sort-by=.lastTimestamp | tail -30` 看最近事件
- 业务侧验证:登录关键业务做一次端到端调用

确认稳定后再进入下一步。

---

## 四、master-2 / master-3 重复

完全重复 **3.1 ~ 3.7**,只是把所有 `master-1` 改成对应的节点名。

> **提醒**:每台之间至少间隔 5 分钟,确认 etcd `endpoint health` 三行全 healthy 之后再动下一台。

---

## 五、整体集群验证(3 台全部完成后)

```bash
BASE=/root/cert-rotate-$(date +%F)

# 1) 3 台 master 证书过期时间都是 1 年后
for h in master-1 master-2 master-3; do
  echo "=== $h ==="
  ssh $h 'kubeadm certs check-expiration | grep -v "CERTIFICATE AUTHORITY"'
done

# 2) 整体节点状态
kubectl get node -o wide | tee $BASE/after-nodes.txt
diff $BASE/baseline-nodes.txt $BASE/after-nodes.txt
# 期望:除了 AGE 列,其它没变化;所有节点 Ready

# 3) 系统组件
kubectl get pod -n kube-system -o wide | tee $BASE/after-kube-system.txt
# 期望:apiserver/cm/scheduler/etcd 各 3 个,coredns / kube-proxy 全 Running
#       RESTARTS 数比基线 +1(只重启了一次)

# 4) 业务命名空间快速扫一遍
kubectl get pod -A | grep -vE 'Running|Completed' | tee $BASE/after-bad-pods.txt
# 期望:输出只有表头一行(没有异常 Pod)

# 5) etcd 集群
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table | tee $BASE/after-etcd.txt

# 6) apiserver 多副本健康
kubectl get --raw='/readyz?verbose' | tail -5

# 7) kubelet 客户端证书也已自动轮换过(可选确认)
for h in master-1 master-2 master-3 <worker-1> <worker-2>; do
  echo "=== $h ==="
  ssh $h 'ls -lt /var/lib/kubelet/pki/ | head -5'
done

# 8) 业务侧 SLO 验证(按你们具体业务)
#  - ingress 入口 curl 一遍
#  - 数据库 / 中间件健康
#  - 监控大盘:Prometheus targets up,Grafana 面板无红
```

把 before / after 两份归档保留至少 30 天:

```bash
tar czf /root/cert-rotate-$(date +%F).tar.gz /root/cert-rotate-$(date +%F)/
```

---

## 六、回滚

> 触发条件:**3.6 验证不通过**,或重启后 apiserver / etcd 起不来。

### 6.1 回滚单台 master(没影响到 etcd)

```bash
TS=<你备份时记下的时间戳,例如 2026-06-01-1430>
BAK=/root/cert-rotate-${TS}

# 1) 整体恢复 /etc/kubernetes(因为是 cp -a 整目录备份,直接覆盖回去)
mv /etc/kubernetes /etc/kubernetes.broken.$(date +%s)   # 留现场,别 rm
cp -a ${BAK}/etc-kubernetes /etc/kubernetes

# 2) 恢复 admin kubeconfig
cp -f /etc/kubernetes/admin.conf /root/.kube/config

# 3) 触发 static pod 重建(kubelet 会感知到 manifests 时间戳变化)
cd /etc/kubernetes/manifests
for f in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml; do
    mv $f /tmp/$f; sleep 20; mv /tmp/$f .; sleep 30
done

# 4) kubelet 重新加载
systemctl restart kubelet
```

然后回到 **3.6** 跑一遍验证。

### 6.2 etcd 整体异常(quorum 丢失)

走 [../etcd/etcd-restore.sh](../etcd/etcd-restore.sh) 从 2.3 步存的 `etcd-snapshot.db` 恢复。
**这是最坏情况,操作前先 stop 所有 master 的 etcd static pod 再恢复**,详见 etcd 目录 README。

---

## 七、常见坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `kubectl` 报 `x509: certificate has expired` | `/root/.kube/config` 还是旧的 | 3.3 那步漏了,重新 `cp -f /etc/kubernetes/admin.conf /root/.kube/config` |
| `renew all` 报某个 `*.conf` 不存在 | 老集群少 `super-admin.conf` 之类的(1.29+ 才加的) | 缺什么补什么:`kubeadm init phase kubeconfig <name>`;也可以指定 `kubeadm certs renew <具体名字>` 跳过缺失的 |
| 重启 apiserver 后报 `Unable to register node ... x509` | 工作节点 kubelet 还连着旧 apiserver,且没自动轮换 | 99% 是 worker 的 `kubelet.conf` 里嵌的客户端证书过期了。在 worker 上:`kubeadm certs renew all` 不适用(worker 上没 CA),改用 `kubeadm certs renew kubelet-client` 失败的话最简单是 `kubeadm token create --print-join-command` + 重新 join,或者直接拷贝 master 上 `kubeadm-kubelet-cert-renew` 流程 |
| `etcd endpoint health` 某个节点 `unhealthy` | 这台 etcd 还没起来 | 等 30s,看 `crictl ps -a \| grep etcd` 是否 `Exited`;查 `crictl logs <id>` |
| `kube-controller-manager` 不停 leader 选举 | 三台 cm 都在重启的中间窗口 | 没串行,等所有 master 处理完会自动稳定;**未来务必串行** |
| Ingress / cert-manager / metrics-server 证书报错 | 这些是业务证书,跟本流程无关 | 单独按各组件文档处理,本流程没动它们 |

---

## 八、日历提醒

证书续完一年后又会过期。**建议加日历**:

- T+330 天:再做一次本流程(留 35 天缓冲)
- T+350 天:Prometheus 告警 `apiserver_client_certificate_expiration_seconds < 30*86400` 触发,作为兜底

监控规则示例:

```yaml
- alert: KubeClientCertificateExpirationSoon
  expr: apiserver_client_certificate_expiration_seconds_count{job="apiserver"} > 0
        and on(job)
        histogram_quantile(0.01, sum by (job, le) (rate(apiserver_client_certificate_expiration_seconds_bucket[5m]))) < 30*86400
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "Kubernetes 客户端证书 30 天内过期,尽快续签"
```
