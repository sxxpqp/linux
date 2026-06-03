# Calico On-Premises 部署(eBPF + 替换 kube-proxy)

> 基于 [Tigera 官方 onpremises 文档](https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises) 编写,**已运行集群**的后置部署流程。
> 老 v3.25 manifest 见上一级目录 [calico-v3.25.yaml](../calico-v3.25.yaml)(历史归档,不推荐新装用)。

## 状态

| 状态 | 含义 |
|---|---|
| 🟡 实验 | 仓库内尚未生产验证,先在测试集群跑 |

---

## TL;DR

```bash
# Operator 方式(推荐,生产首选)
bash operator/install.sh --apiserver-host=<LB_IP> --delete-kube-proxy

# Manifest 方式(单文件,排障简单)
bash manifest/install.sh --apiserver-host=<LB_IP> --enable-ebpf --delete-kube-proxy
```

---

## 文件结构

```
onpremises/
├── README.md                                # 本文档
├── operator/                                # 官方推荐:Tigera Operator 模式
│   ├── install.sh                           # 安装脚本(7 步流程,自动 CIDR 探测)
│   ├── uninstall.sh                         # 卸载脚本(默认 dry-run,自动恢复 kube-proxy)
│   ├── installation.yaml                    # Installation CR(BPF dataplane,CIDR 用占位符)
│   └── kubernetes-services-endpoint.yaml    # 让 Calico 直连 API server(替换 kube-proxy 必需)
└── manifest/                                # 经典:单 calico.yaml
    ├── install.sh                           # 装完后手动 patch FelixConfiguration 开 eBPF
    └── uninstall.sh                         # 卸载脚本(默认 dry-run)
```

---

## Calico eBPF 还需要 kube-proxy 吗?

**结论:不需要,Calico 官方推荐替换掉。**

### 三种模式对比

| 模式 | Service DNAT 由谁做 | 内核要求 | 性能 | 适用 |
|---|---|---|---|---|
| iptables(传统) | kube-proxy | 任意 | O(N) 链表,服务多了慢 | 老内核 / 兼容兜底 |
| ipvs | kube-proxy | 3.18+ | O(1) 哈希,但 conntrack 仍走完整协议栈 | 中等规模,不动 CNI |
| **Calico eBPF + 无 kube-proxy** | **Calico Felix**(TC hook) | **5.3+ 强制,5.10+ 稳** | 网卡 ingress 就完成 DNAT,跳过部分协议栈,保真 source IP | 5.3+ 内核 + 想要性能/可观测 |

### eBPF 的真实收益

| 维度 | 收益 |
|---|---|
| NodePort P99 延迟 | 降 20-40%(服务数越多越明显) |
| 大量 Service 场景 CPU | 显著降低(iptables 链长才有差别,<200 svc 不明显) |
| Source IP 保留 | NodePort 默认不丢源 IP(iptables 模式需 `externalTrafficPolicy: Local`) |
| 可观测 | `calico-node -bpf conntrack dump` 直接抓表 |

### 硬约束(踩坑点)

1. **内核 5.3+**,5.10+ 稳。CentOS 7 (3.10) **放弃**,Rocky 9 / Ubuntu 22.04 起步。
2. **顺序绝不能反**:先配 `kubernetes-services-endpoint` → 切 BPF → 再删 kube-proxy。
   反过来:删了 kube-proxy 后 Calico Pod 自己访问 `kubernetes.default` 这个 ClusterIP 失败 → operator/controller 全断 → 集群死锁。
3. **HA 集群必须填 LB 地址**,不能用单 master IP,否则 LB 故障后 Calico 失联。
4. **不支持的特性**:
   - Windows 节点(eBPF dataplane 不支持)
   - 某些 `sessionAffinity` 历史字段
   - 已弃用的 `topologyKeys`
5. **HostPort + eBPF** 曾有 bug,选版本前看 [release note](https://github.com/projectcalico/calico/releases)。

→ 不满足这些就用 ipvs 模式 + 保留 kube-proxy,够用。

---

## 两种方式怎么选?

| 维度 | Operator | Manifest |
|---|---|---|
| 部署文件数 | 3(operator + Installation CR + APIServer CR) | 1(calico.yaml) |
| eBPF 切换 | Installation CR 一行 `linuxDataplane: BPF` | 改 ConfigMap + patch FelixConfiguration,2 步 |
| 升级 | `kubectl patch installation default --type=merge -p '{"spec":{"variant":"Calico"}}'` 改 CR | 重新 apply 完整 yaml |
| 资源占用 | 多 1 个 operator deploy(~50MB) | 无额外 |
| 排障 | 看 operator 日志 + Installation/APIServer/FelixConfiguration 多个资源 | 直接看 calico-node 日志 |
| 多版本切换 | 一行 CR 字段 | 重装 |
| **推荐** | ✅ 新装、需要 eBPF、希望未来好升级 | 老集群兼容、改 image / env 频繁、希望排障路径短 |

> 官方从 v3.20 起 onpremises 文档把 operator 放在前面,manifest 放在后面"alternative",**新装建议 operator**。

---

## 部署流程(详解)

### Operator 方式

```bash
# 1. 看一眼参数(必须传 LB 地址,不传会用 endpoint 自动探测但只适合单 master)
bash operator/install.sh --help

# 2. 第一次先不删 kube-proxy,装完跑业务验证
bash operator/install.sh \
  --apiserver-host=192.168.1.100 \
  --apiserver-port=6443 \
  --pod-cidr=192.168.0.0/16 \
  --calico-version=v3.28.2

# 3. 业务验证通过(curl ClusterIP / NodePort 都通,Pod 间通信正常)

# 4. 验证 BPF 真在跑
kubectl -n calico-system exec -it ds/calico-node -- calico-node -bpf conntrack dump | head
kubectl get felixconfiguration default -o yaml | grep bpfEnabled
# 期望: bpfEnabled: true

# 5. 删 kube-proxy
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy

# 6. 每个 node 清理 iptables 残留
ssh node-N "iptables-save | grep -v KUBE | iptables-restore"
# ipvs 模式额外:
ssh node-N "ipvsadm -C"
```

或者一步到位(自动删 kube-proxy,先在测试集群跑):

```bash
bash operator/install.sh --apiserver-host=192.168.1.100 --delete-kube-proxy
```

### Manifest 方式

```bash
# 装 + 开 eBPF + 删 kube-proxy 一条命令
bash manifest/install.sh \
  --apiserver-host=192.168.1.100 \
  --enable-ebpf \
  --delete-kube-proxy

# 或保守:只装,保留 kube-proxy
bash manifest/install.sh --pod-cidr=10.244.0.0/16
```

---

## 关键检查命令

| 检查项 | 命令 | 期望 |
|---|---|---|
| Calico Pod 全 Ready | `kubectl -n calico-system get pods` / `kubectl -n kube-system get pods -l k8s-app=calico-node` | 全部 Running |
| BPF dataplane 启用 | `kubectl get felixconfiguration default -o jsonpath='{.spec.bpfEnabled}'` | `true` |
| kubernetes-services-endpoint 存在 | `kubectl -n tigera-operator get cm kubernetes-services-endpoint -o yaml`(operator)<br>`kubectl -n kube-system get cm kubernetes-services-endpoint -o yaml`(manifest) | `KUBERNETES_SERVICE_HOST` 是 LB IP |
| kube-proxy 已删 | `kubectl -n kube-system get ds kube-proxy` | NotFound |
| BPF Service 表有内容 | `kubectl -n calico-system exec -it ds/calico-node -- calico-node -bpf nat dump \| head` | 有 ClusterIP → Pod IP 映射 |
| Pod 互通 | 跨节点起两个 Pod `kubectl run --image=nginx a; kubectl run --image=curlimages/curl b -it -- curl <a-pod-ip>` | 200 OK |
| Service 互通 | `kubectl run b -it --image=curlimages/curl -- curl http://kubernetes.default.svc:443 -k` | 401(说明 ClusterIP 转发到 API server 了) |

---

## 卸载 Calico

两个 uninstall.sh 都**默认 dry-run**,加 `--apply` 才真删。

⚠ **核心约束**:卸 Calico 等于拿掉 Service DNAT 引擎。**集群必须始终有一个**做 DNAT 的组件(kube-proxy / Calico eBPF / Cilium eBPF / ...)。卸载后接下来必须有人接,否则集群 Service 立即全断。

### 三种卸载后续路径(你选)

| 路径 | 命令 | 适用 |
|---|---|---|
| **A. 回退到 kube-proxy 传统模式** | `bash operator/uninstall.sh --apply --restore-kube-proxy` | 大多数情况,保险 |
| **B. 立即装别的 eBPF CNI(Cilium 等)** | `bash operator/uninstall.sh --apply` + 立即装 Cilium | 想继续用 eBPF,只是换实现 |
| **C. 集群不要了,直接重置** | `kubeadm reset -f` | 实验环境 |

### 默认行为(不指定 `--restore-kube-proxy` 时)

脚本**不会**自动恢复 kube-proxy,只在 kube-proxy 已删除的情况下打印一段醒目警告 + 10 秒倒计时,让你确认是要走路径 B/C(或 Ctrl-C 重跑加 `--restore-kube-proxy`)。

### 关键顺序(脚本已固化,改了就是 bug)

1. **先**切回 Iptables dataplane(让 Calico Felix 停止清理 iptables 规则)
2. **再**(可选)恢复 kube-proxy
3. **然后**删 Installation/APIServer CR(operator 自动清理 calico-system)
4. 反向 `kubectl delete -f tigera-operator.yaml`
5. 删 tigera-operator namespace
6. 打印每个节点要执行的清理命令(iptables / cni / bpf 残留)

顺序反了 → kube-proxy 装回去会被 Felix 当作残留清掉 → DS 永远不 Ready(踩坑表里有这条)。

### 常用命令

```bash
# 看计划(必跑,核对状态)
bash operator/uninstall.sh

# 卸载并回退到 kube-proxy 模式(最常见,无 eBPF 需求时)
bash operator/uninstall.sh --apply --restore-kube-proxy

# 卸载,接下来手动装 Cilium 接管(保持 eBPF)
bash operator/uninstall.sh --apply

# namespace 卡 Terminating 强清
bash operator/uninstall.sh --apply --force --restore-kube-proxy
```

卸载脚本**不会**自动 ssh 到节点清理 iptables/cni 残留 — 设计上故意的,避免误操作。会打印精确命令,你 ssh 上去跑。

manifest 版本流程相似但更短(5 步),没有 operator/CR 这一层。

## 回滚:从 eBPF 退回 iptables + kube-proxy

```bash
# 1. 先恢复 kube-proxy(用集群 kubeadm 配置生成)
kubeadm init phase addon kube-proxy --apiserver-advertise-address=<LB_IP>

# 2. 关 BPF
kubectl patch felixconfiguration default --type=merge -p '{"spec":{"bpfEnabled": false}}'

# 3. Operator 方式还要改 Installation CR
kubectl patch installation default --type=merge -p '{"spec":{"calicoNetwork":{"linuxDataplane":"Iptables"}}}'

# 4. 重启 calico-node
kubectl -n calico-system rollout restart ds/calico-node  # operator
kubectl -n kube-system   rollout restart ds/calico-node  # manifest
```

---

## 下载源 vs 镜像源(两件事别搞混)

| 类型 | 走什么 | 为什么 |
|---|---|---|
| **YAML manifest**(`tigera-operator.yaml` / `calico.yaml`) | Nexus raw 代理(默认硬编码) | GitHub raw 直连国内基本不通,见 [CLAUDE.md 已知踩坑 #1](../../../CLAUDE.md#已知踩坑跨项目通用) |
| **容器镜像**(`calico/node:v3.28.x` 等) | quay.io / docker.io 直连(本仓库当前默认) | 拉 Calico image 一般能通,集群多数节点都能直连 |

YAML 下载源切回上游(临时调试用):

```bash
NEXUS_RAW=https://raw.githubusercontent.com bash operator/install.sh ...
```

## 镜像源(如果内网拉 quay.io 慢)

按 [仓库 CLAUDE.md "Harbor 架构"](../../../CLAUDE.md#harbor-架构关键) 改 image。

**Operator 方式**:`installation.yaml` 取消注释 `spec.registry`:

```yaml
spec:
  registry: quay.ihome.sxxpqp.top:8443/
```

**Manifest 方式**:`install.sh` 下载 yaml 后加一段 sed:

```bash
sed -i 's|quay.io/calico/|quay.ihome.sxxpqp.top:8443/calico/|g' "$TMP_YAML"
sed -i 's|docker.io/calico/|dockerhub.ihome.sxxpqp.top:8443/calico/|g' "$TMP_YAML"
```

containerd 加速源配置见 [CLAUDE.md "Docker / containerd 加速源配置"](../../../CLAUDE.md#docker--containerd-加速源配置)。

---

## 踩坑速查

| 现象 | 原因 | 修法 |
|---|---|---|
| operator 日志报 `IPPool X is not within the platform's configured pod network CIDR(s) [Y]`,`calico-system` namespace 一直不建 | Installation CR `cidr` 跟 kubeadm `--pod-network-cidr` 不一致,**operator 模式严格校验,manifest 模式不校验** | `kubectl -n kube-system get cm kubeadm-config -o yaml \| grep podSubnet` 确认真实值,然后 `kubectl patch installation default --type=merge -p '{"spec":{"calicoNetwork":{"ipPools":[{"name":"default-ipv4-ippool","cidr":"<真实CIDR>","encapsulation":"VXLANCrossSubnet","natOutgoing":"Enabled","nodeSelector":"all()"}]}}}'` |
| 卸载/回滚时 `kubeadm init phase addon kube-proxy` 装回 kube-proxy 后 DS 永远 `2/3 ready`,`rollout status` 超时 | Calico BPF 模式默认 `bpfKubeProxyIptablesCleanupEnabled=true`,主动清理 kube-proxy 的 iptables 规则 → kube-proxy readiness 失败 | **必须先切回 Iptables dataplane 再恢复 kube-proxy**:`kubectl patch installation default --type=merge -p '{"spec":{"calicoNetwork":{"linuxDataplane":"Iptables"}}}'` → 等 calico-node rollout → 删卡的 kube-proxy Pod 让它重启 |
| 删 kube-proxy 后 calico-node CrashLoop | 没配 `kubernetes-services-endpoint` ConfigMap,Pod 访问 `kubernetes.default` 失败 | 先配 ConfigMap → 重启 calico-node → 再删 kube-proxy |
| `bpfEnabled: true` 但日志没 BPF | calico-node 没重启或 operator 还没同步 | `kubectl rollout restart ds/calico-node`,等 60s |
| NodePort 通,ClusterIP 不通 | BPF nat 表没建好,通常是 ConfigMap 里 host/port 写错 | 进 calico-node Pod `calico-node -bpf nat dump` 看有没有目标 service |
| 节点 iptables 还有 KUBE-* 链 | 删 kube-proxy 不会清残留 | 手动 `iptables-save \| grep -v KUBE \| iptables-restore` |
| Pod 跨子网不通 | `encapsulation: None`(纯 BGP)但路由没宣告 | 改 `VXLANCrossSubnet` 兜底,或配 BGP peer |
| HA 集群 LB 重启后 Calico 全断 | `KUBERNETES_SERVICE_HOST` 填的单 master IP 不是 VIP | 改成 VIP 重启 calico-node |

---

## 参考

- 官方 onpremises: https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises
- 启用 eBPF: https://docs.tigera.io/calico/latest/operations/ebpf/enabling-ebpf
- eBPF 限制: https://docs.tigera.io/calico/latest/reference/ebpf/limitations
- Felix 配置参考: https://docs.tigera.io/calico/latest/reference/resources/felixconfig
- 仓库共享设施: [../../../CLAUDE.md](../../../CLAUDE.md)
