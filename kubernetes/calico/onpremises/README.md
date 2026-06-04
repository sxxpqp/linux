# Calico On-Premises 部署(eBPF + 替换 kube-proxy)

> 基于 [Tigera 官方 onpremises 文档](https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises) 编写,**已运行集群**的后置部署流程。
> 老 v3.25 manifest 见上一级目录 [calico-v3.25.yaml](../calico-v3.25.yaml)(历史归档,不推荐新装用)。

## 状态

| 状态 | 含义 |
|---|---|
| ✅ 生产验证 | operator↔manifest 交叉安装/卸载, 反复多次验证通过 |

---

## TL;DR

```bash
# Operator 方式(推荐,生产首选)
bash operator/install.sh --apiserver-host=<LB_IP> --delete-kube-proxy

# Manifest 方式(单文件,排障简单, kube-proxy 不在时自动开 BPF)
bash manifest/install.sh --delete-kube-proxy

# 装完验证连通性
bash test-connectivity.sh
```

---

## 文件结构

```
onpremises/
├── README.md                                # 本文档
├── operator/                                # 官方推荐:Tigera Operator 模式
│   ├── install.sh                           # 安装(自动 CIDR 探测, --delete-kube-proxy 可选)
│   ├── uninstall.sh                         # 卸载(默认 dry-run, --apply 真删)
│   ├── installation.yaml                    # Installation CR(BPF dataplane, CIDR 用占位符)
│   └── kubernetes-services-endpoint.yaml    # Calico 直连 API server(替换 kube-proxy 必需)
├── manifest/                                # 经典:单 calico.yaml
│   ├── install.sh                           # 安装(kube-proxy 不在时自动开 BPF)
│   └── uninstall.sh                         # 卸载(含 operator 残留 namespace 清理)
└── ../test-connectivity.sh                  # 连通性验证脚本(安装后跑一次)
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
2. **顺序问题已由脚本自动处理**: `kubernetes-services-endpoint` ConfigMap → 装 Calico → 开 BPF service NAT → 删 kube-proxy。手动操作时注意别反过来。
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
# 一步到位(删 kube-proxy + BPF service NAT)
bash operator/install.sh --apiserver-host=172.16.150.128 --delete-kube-proxy

# 保守:保留 kube-proxy 共存(BPF 和 kube-proxy 都在跑)
bash operator/install.sh --apiserver-host=172.16.150.128
```

脚本会自动:
- 探测 kubeadm Pod CIDR
- 配 `kubernetes-services-endpoint` ConfigMap(绕过 kube-proxy 直连 API server)
- Patch FelixConfiguration 开启 kube-proxy replacement
- 重启 calico-node 加载 service NAT

### Manifest 方式

```bash
# 一步到位(删 kube-proxy → 自动开 BPF)
bash manifest/install.sh --delete-kube-proxy

# kube-proxy 不在时自动开 BPF,不需要传 --enable-ebpf
bash manifest/install.sh
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

```bash
# dry-run 看计划
bash operator/uninstall.sh
# 真删
bash operator/uninstall.sh --apply

# manifest 同理
bash manifest/uninstall.sh --apply
```

卸载脚本会自动:
- 强杀残留 Pod + 剥 namespace finalizer(`calico-system` / `calico-apiserver` / `tigera-operator`)
- 反向 delete operator/manifest yaml(一次性带走 CRD / RBAC / DS / Deploy)
- 打印每个节点需手动执行的残留清理命令

⚠ **核心约束**: 卸载 Calico = 拿掉 Service DNAT 引擎。如果打算换 CNI, 卸载后立即装新的。如果是短期实验, 先跑 `kubeadm reset -f` 重建集群。


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
| `install-cni` CrashLoop: `dial tcp 10.96.0.1:443: connection refused` | kube-proxy 不在且缺 `kubernetes-services-endpoint` ConfigMap | 脚本已自动建;手动: `kubectl -n kube-system create cm kubernetes-services-endpoint --from-literal=KUBERNETES_SERVICE_HOST=<node_ip> --from-literal=KUBERNETES_SERVICE_PORT=6443` |
| `calico-kube-controllers` 无法初始化: `dial tcp 10.96.0.1:443` | BPF 没开, kube-proxy 又不在 → ClusterIP 无人 NAT | operator: 检查 FelixConfiguration.bpfKubeProxyIptablesCleanupEnabled; manifest: 脚本已自动检测并开 BPF |
| ClusterIP/NodePort 通但 DNS 不通 | `bpfKubeProxyIptablesCleanupEnabled` 没开 | `kubectl patch felixconfiguration default --type=merge -p '{"spec":{"bpfKubeProxyIptablesCleanupEnabled":true}}' && kubectl -n calico-system rollout restart ds/calico-node` |
| operator 装完 calico-system 不出现 | Installation CR `cidr` 跟 kubeadm `--pod-network-cidr` 不一致 | `kubectl -n kube-system get cm kubeadm-config -o yaml \| grep podSubnet`, 然后 `kubectl patch installation default --type=merge -p '{"spec":{"calicoNetwork":{"ipPools":[{"cidr":"<真实CIDR>"}]}}}'` |
| namespace calico-system/calico-apiserver 卡 Terminating | Pod 残留 finalizer 没清, CRD 已删 | 脚本自动处理; 手动: `kubectl -n <ns> delete pods --all --force --grace-period=0` → 剥 finalizer |
| operator↔manifest 交叉安装后重装卡住 | manifest 卸载删了 CRD, operator 残留 namespace 没人清 | manifest uninstall 已加自动清理; 手动: `kubectl delete ns calico-system calico-apiserver --force` |
| `bpfEnabled: true` 但 BPF 没跑 | FelixConfiguration 是 `projectcalico.org/v3`(operator) 但 manifest 用 `crd.projectcalico.org/v1` | 脚本已用正确 apiVersion; 手动: `kubectl apply -f - <<< "apiVersion: crd.projectcalico.org/v1 ..."` |
| 节点 iptables 还有 KUBE-* 链 | 删 kube-proxy 不会清残留 | 重启节点最干净; 留着也无害。**不要** `iptables-save \| grep -v KUBE \| iptables-restore` |

---

## 参考

- 官方 onpremises: https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises
- 启用 eBPF: https://docs.tigera.io/calico/latest/operations/ebpf/enabling-ebpf
- eBPF 限制: https://docs.tigera.io/calico/latest/reference/ebpf/limitations
- Felix 配置参考: https://docs.tigera.io/calico/latest/reference/resources/felixconfig
- 仓库共享设施: [../../../CLAUDE.md](../../../CLAUDE.md)
