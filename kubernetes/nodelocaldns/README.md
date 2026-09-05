# NodeLocal DNSCache

NodeLocal DNSCache 给每个节点跑一个本地 DNS 缓存，减少 Pod DNS 查询跨节点访问 kube-dns/CoreDNS 的延迟和 conntrack 压力。

> 状态: 验证过
> 上游文档: https://kubernetes.io/zh-cn/docs/tasks/administer-cluster/nodelocaldns/

## 直接使用

先确认 kube-proxy 模式：

```bash
kubectl -n kube-system get cm kube-proxy -o jsonpath='{.data.config\.conf}' | grep -E '^[[:space:]]*mode:'
```

### kube-proxy iptables 模式

```bash
bash kubernetes/nodelocaldns/install-iptables.sh
```

自定义本地 DNS IP / 集群域：

```bash
bash kubernetes/nodelocaldns/install-iptables.sh \
  --local-dns=169.254.20.10 \
  --domain=cluster.local
```

### kube-proxy IPVS 模式

```bash
bash kubernetes/nodelocaldns/install-ipvs.sh
```

IPVS 模式装完后，还要把每个节点 kubelet 的 `--cluster-dns` 改成 NodeLocal DNS IP，例如 `169.254.20.10`，然后重启 kubelet 并重建业务 Pod：

```bash
# 每个节点执行，具体文件路径按 kubeadm / 二进制部署方式确认
grep -R "cluster-dns" /var/lib/kubelet /etc/systemd/system /etc/default /etc/sysconfig 2>/dev/null

systemctl daemon-reload
systemctl restart kubelet
```

> 只有新建 / 重建后的 Pod 才会重新生成 `/etc/resolv.conf`。

## 官方 sed 手动渲染方式

如果不跑本仓库脚本，也可以完全按官方文档思路用 `sed` 先把模板渲染出来再 apply。

> 建议先 `cp` 一份临时文件再 `sed -i`，不要直接把仓库里的 [nodelocaldns.yaml](nodelocaldns.yaml) 模板改脏。

### iptables 模式

```bash
# 出于历史原因，CoreDNS 的 Service 被命名为 kube-dns
coredns=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
domain=cluster.local
localdns=169.254.20.10

cp kubernetes/nodelocaldns/nodelocaldns.yaml /tmp/nodelocaldns-iptables.yaml

sed -i \
  -e "s/__PILLAR__LOCAL__DNS__/${localdns}/g" \
  -e "s/__PILLAR__DNS__DOMAIN__/${domain}/g" \
  -e "s/__PILLAR__DNS__SERVER__/${coredns}/g" \
  /tmp/nodelocaldns-iptables.yaml

kubectl apply -f /tmp/nodelocaldns-iptables.yaml
kubectl -n kube-system rollout status ds/node-local-dns --timeout=300s
```

iptables 模式下，`node-local-dns` 会同时监听：

- `${localdns}`
- kube-dns Service IP：`${coredns}`

所以 Pod 继续使用原 kube-dns Service IP，或后续把 kubelet `--cluster-dns` 改成 `${localdns}`，都能走到 NodeLocal DNSCache。

### IPVS 模式

```bash
# 出于历史原因，CoreDNS 的 Service 被命名为 kube-dns
coredns=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
domain=cluster.local
localdns=169.254.20.10

cp kubernetes/nodelocaldns/nodelocaldns.yaml /tmp/nodelocaldns-ipvs.yaml

sed -i \
  -e "s/__PILLAR__LOCAL__DNS__/${localdns}/g" \
  -e "s/__PILLAR__DNS__DOMAIN__/${domain}/g" \
  -e 's/,__PILLAR__DNS__SERVER__//g' \
  -e 's/ __PILLAR__DNS__SERVER__//g' \
  -e "s/__PILLAR__CLUSTER__DNS__/${coredns}/g" \
  /tmp/nodelocaldns-ipvs.yaml

kubectl apply -f /tmp/nodelocaldns-ipvs.yaml
kubectl -n kube-system rollout status ds/node-local-dns --timeout=300s
```

说明：官方文档里关键是删除 `,__PILLAR__DNS__SERVER__` 并把 `__PILLAR__CLUSTER__DNS__` 替换为 kube-dns Service IP；本仓库模板的 Corefile `bind` 行还有一个空格形式的 ` __PILLAR__DNS__SERVER__`，所以这里额外加了：

```bash
-e 's/ __PILLAR__DNS__SERVER__//g'
```

IPVS 模式下，kube-dns Service IP 已经被 `kube-ipvs0` 占用，`node-local-dns` 只能监听 `${localdns}`。因此还必须把每个节点 kubelet 的 `--cluster-dns` 改成 `${localdns}`，并重建业务 Pod。

## 两种模式差异

| 项 | iptables | IPVS |
|---|---|---|
| node-cache 监听地址 | `<localdns>` + `kube-dns Service IP` | 只监听 `<localdns>` |
| 是否替换 `__PILLAR__DNS__SERVER__` | 替换为 kube-dns Service IP | 删除 `,__PILLAR__DNS__SERVER__` 和 ` __PILLAR__DNS__SERVER__` |
| 是否替换 `__PILLAR__CLUSTER__DNS__` | 不需要，node-cache 启动后自动设置 | 替换为 kube-dns Service IP |
| Pod DNS 生效方式 | 原 kube-dns Service IP / kubelet 改成本地 IP 都可 | 必须把 kubelet `--cluster-dns` 改成本地 IP |
| 原因 | iptables 不独占 Service IP | IPVS 的 `kube-ipvs0` 已占用 Service IP，node-cache 不能再 bind |

## 脚本做了什么

### install-iptables.sh

等价于官方文档的：

```bash
coredns=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
domain=cluster.local
localdns=169.254.20.10

sed -i "s/__PILLAR__LOCAL__DNS__/$localdns/g; s/__PILLAR__DNS__DOMAIN__/$domain/g; s/__PILLAR__DNS__SERVER__/$coredns/g" nodelocaldns.yaml
kubectl apply -f nodelocaldns.yaml
```

### install-ipvs.sh

等价于官方文档的：

```bash
coredns=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}')
domain=cluster.local
localdns=169.254.20.10

sed -i "s/__PILLAR__LOCAL__DNS__/$localdns/g; s/__PILLAR__DNS__DOMAIN__/$domain/g; s/,__PILLAR__DNS__SERVER__//g; s/__PILLAR__CLUSTER__DNS__/$coredns/g" nodelocaldns.yaml
kubectl apply -f nodelocaldns.yaml
```

本仓库脚本另外补了：

- 自动读取 `kube-system/kube-dns` 的 ClusterIP
- `--dry-run` 做 server-side dry-run
- `--output=FILE` 只生成渲染后的 YAML，不 apply
- `rollout status ds/node-local-dns --timeout=300s` 等待 DaemonSet Ready

## 验证

```bash
kubectl -n kube-system get ds node-local-dns -o wide
kubectl -n kube-system get pod -l k8s-app=node-local-dns -o wide
kubectl -n kube-system logs -l k8s-app=node-local-dns --tail=80
```

新建测试 Pod 验证解析：

```bash
kubectl run dns-test --rm -it --restart=Never \
  --image=busybox:1.36 \
  -- nslookup kubernetes.default.svc.cluster.local
```

看 Pod 使用的 DNS：

```bash
kubectl run resolv-test --rm -it --restart=Never \
  --image=busybox:1.36 \
  -- cat /etc/resolv.conf
```

预期：

- iptables 模式：`nameserver` 可能是 kube-dns Service IP，也可能是 `169.254.20.10`，两者都能命中 node-cache。
- IPVS 模式：`nameserver` 应该是 `169.254.20.10`；如果还是 kube-dns Service IP，说明 kubelet `--cluster-dns` 没改或 Pod 还没重建。

## 卸载

```bash
kubectl -n kube-system delete ds node-local-dns --ignore-not-found
kubectl -n kube-system delete svc node-local-dns kube-dns-upstream --ignore-not-found
kubectl -n kube-system delete cm node-local-dns --ignore-not-found
kubectl -n kube-system delete sa node-local-dns --ignore-not-found
```

IPVS 模式如果改过 kubelet `--cluster-dns`，卸载前先把 kubelet DNS 改回 kube-dns Service IP，再重启 kubelet、重建 Pod。

## 注意

- `nodelocaldns.yaml` 保持官方占位符模板，不直接写死集群 IP。
- 镜像保持上游 `registry.k8s.io/dns/k8s-dns-node-cache:1.26.8`，节点 containerd mirror 会透明转发，不要改成私有镜像地址。
- 如果本机已有服务占用 `169.254.20.10:53` 或 53 端口，DaemonSet 会启动失败；先检查 `kubectl -n kube-system describe pod -l k8s-app=node-local-dns`。
