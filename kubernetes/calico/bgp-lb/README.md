# Calico BGP + 内置 LoadBalancer(生产:ECMP + ingress DS)

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/calico/bgp-lb/README.md
> 状态: ✅ 生产验证

Calico BIRD 一套 BGP **同时宣告 Pod CIDR + LoadBalancer Service IP**,不再需要 MetalLB / kube-vip。多节点宣告同一 LB IP → 路由器走 **BGP ECMP** 做 L3 负载均衡 → 流量散到多个 ingress-nginx DS 实例。LB IP 自动分配,建 Service 即用。

## TL;DR

```bash
# 1. 装 Calico BGP-LB
bash install.sh --apiserver-host=172.16.150.128 --my-asn=64500 \
  --lb-cidr=172.16.150.200/29 \
  --peer-asn=64500 --peer-address=172.16.150.131

# 2. 装 ingress-nginx(DaemonSet 跑在 node1/node2,Service 类型 LoadBalancer)
bash ../../ingress-nginx/install.sh --label-nodes=node1,node2

# 3. 看 LB IP 自动分配 + BGP ECMP 多路径生效
kubectl get svc -n ingress-nginx ingress-nginx-controller
# 期望 EXTERNAL-IP 出现 172.16.150.200,且路由器侧 ip route 显示 multipath

# 4. 卸载
bash uninstall.sh --apply
```

---

## 生产架构 — BGP ECMP 多路径 + Ingress DS

```
                          ┌──────────────────┐
                          │   外部路由器      │
                          │   AS 64500       │
                          │  (本环境:.131) │
                          └──────┬───────────┘
                                 │
              ip route 172.16.150.200/32:
                proto bird (ECMP, 多 nexthop)
                  nexthop via 172.16.150.129 dev eth0 weight 1   ← node1
                  nexthop via 172.16.150.130 dev eth0 weight 1   ← node2
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
        ┌─────▼─────┐      ┌─────▼─────┐      ┌─────▼─────┐
        │  kh .128  │      │ node1 .129│      │ node2 .130│
        │ control   │      │ ingress DS│      │ ingress DS│
        │  plane    │      │ + worker  │      │ + worker  │
        └───────────┘      └─────┬─────┘      └─────┬─────┘
                                 │                  │
                  ingress-nginx controller (DaemonSet)
                                 │
                   ──────────  Service / Pod CIDR ──────────
                                 │
                      ┌──────────┴──────────┐
                      ▼                     ▼
                  Service A             Service B
                (业务 ClusterIP)      (业务 ClusterIP)
```

### 4 层协作

| 层 | 组件 | 干什么 |
|---|---|---|
| ① 路由发现 | Calico BIRD(每节点) | 跟外部路由器建 BGP peer,**宣告**本节点持有的 Pod CIDR 子段 + LB IP |
| ② ECMP 负载均衡 | 外部路由器 | 收到 N 个相同 prefix(`172.16.150.200/32`)的 BGP 通告,**安装 N 条 nexthop**(ECMP),按流哈希 |
| ③ 入口流量 | ingress-nginx DS | 跑在多节点(`hostNetwork: true` 直用宿主网络,或 Service LB),接收路由器送来的流量 |
| ④ 业务流量 | Service + Pod | ingress 路由到后端 ClusterIP → kube-proxy / Calico 数据面送到 Pod |

### BGP ECMP 工作原理

1. **LB Service 创建** → `lb-assigner` 从 `--lb-cidr` 池里挑一个 IP 填进 `.status.loadBalancer.ingress[].ip`
2. **Calico 监听** → 看到 LB IP 后,**所有有该 Service backend Pod 的节点**(externalTrafficPolicy=Cluster 时:**所有节点**)通过 BGP 把 `LB_IP/32` 宣告出去
3. **路由器收到 N 条同 prefix 路由** → 内核 / 路由表合并成 ECMP 多路径,按 `(src_ip, src_port, dst_ip, dst_port, proto)` 5-tuple 哈希挑 nexthop
4. **同一连接稳定到同一节点**(避免乱序);不同连接散到多节点 → 负载均衡

> ⚠ `externalTrafficPolicy: Local` 时只有跑了 backend Pod 的节点会宣告 → ECMP 路径数 = 节点 Pod 数。`Cluster` 时所有节点都宣告(可能多此一跳 SNAT,但 ECMP 更均衡)。Ingress DS 推荐 **Local**(每节点都有 Pod,路径数等于 DS 实例数)。

---

## ingress-nginx DaemonSet 部署模型

| 字段 | 推荐 | 理由 |
|---|---|---|
| `kind` | **DaemonSet** | 每个标记节点一个实例,故障域隔离,ECMP 多路径靠这个 |
| `nodeSelector` | `ingress=true`(用 `--label-nodes=node1,node2` 自动打) | 只在专门的入口节点跑,跟业务节点解耦 |
| `Service.type` | **LoadBalancer**(配合 Calico BGP) | 拿到 LB IP,被 BGP 宣告 |
| `Service.externalTrafficPolicy` | **Local** | 保留客户端真实 IP + ECMP 路径数等于 DS 实例数 |
| `hostNetwork` | 看情况:中小集群 `true`(80/443 直绑宿主) / 大集群 `false`(Service LB) | hostNetwork 模式 ingress 直接吃宿主 80/443,跳过一层 kube-proxy |

详情和 yaml 模板见 [../../ingress-nginx/README.md](../../ingress-nginx/README.md)。

---

## 文件

| 文件 | 状态 | 说明 |
|---|---|---|
| [install.sh](install.sh) | ✅ | BGP 安装:operator + BGPConfiguration + BGPPeer + LB 自动分配器 |
| [uninstall.sh](uninstall.sh) | ✅ | 卸载:剥 CR finalizer + 清 namespace,默认 dry-run |
| [installation.yaml](installation.yaml) | ✅ | Installation CR:Iptables + BGP + 无 VXLAN |
| [lb-assigner.sh](lb-assigner.sh) | ✅ | LB IP 自动分配器(安装时自动部署为 Deployment) |
| [simulate-router.sh](simulate-router.sh) | ✅ | 外部路由器模拟(FRRouting Docker,用于测试 BGP peering / ECMP) |

## 参数

| 参数 | 必填 | 说明 |
|---|---|---|
| `--apiserver-host` | ✅ | API server 地址 |
| `--my-asn` | ✅ | 集群 BGP AS 号(私有 AS 64512-65534,本环境 64500) |
| `--lb-cidr` | ✅ | LoadBalancer Service IP 段(本环境 `172.16.150.200/29`) |
| `--peer-asn` | 可选 | 上游路由器 AS 号;不传只开 node-mesh(节点间 iBGP) |
| `--peer-address` | 可选 | 上游路由器 BGP IP |

## IP 段规划

| 段 | 用途 |
|---|---|
| `172.16.150.128/25` | 节点 IP(kh .128 / node1 .129 / node2 .130 / node4 .131) |
| `172.16.150.200/29` | **LoadBalancer Service IP**(8 个) |
| `10.244.0.0/16` | Pod CIDR(BGP 宣告) |
| `10.96.0.0/12` | ClusterIP Service CIDR |

> ⚠ LB CIDR 跟节点同段不冲突 — BGP 宣告 `/32` 主机路由,优先级高于 `/24` 子网路由。

## 跟其他模式对比

| | BPF (operator) | BGP (bgp/) | **BGP-LB (本目录)** |
|---|---|---|---|
| dataplane | eBPF | Iptables | Iptables |
| Pod 路由 | VXLAN | BIRD BGP | BIRD BGP |
| Service LB | MetalLB | MetalLB | **Calico 自带 + ECMP** |
| LB IP 分配 | MetalLB 自动 | MetalLB 自动 | **lb-assigner 自动** |
| 入口负载均衡 | kube-proxy | kube-proxy | **路由器 ECMP + ingress DS** |
| kube-proxy | 替换 | 保留 | 保留 |
| 额外组件 | 无 | MetalLB speaker | lb-assigner(1 个 pod) |

---

## 验证

### 1. Calico BGP peer 状态

```bash
# 所有 Established 才算 BGP 正常
kubectl -n calico-system exec ds/calico-node -- birdcl show protocols
```

### 2. BGP 路由(集群侧)

```bash
# 节点应该向路由器宣告:Pod CIDR 子段 + 各 LB IP /32
kubectl -n calico-system exec ds/calico-node -- birdcl show route
```

### 3. ECMP 多路径(路由器侧 — 这是关键)

```bash
# 在路由器 / FRR 容器里跑
ip route show 172.16.150.200/32

# 期望输出:
# 172.16.150.200  proto bird
#         nexthop via 172.16.150.129 dev eth0 weight 1
#         nexthop via 172.16.150.130 dev eth0 weight 1
```

**只有 1 个 nexthop = ECMP 没生效**。常见原因:
- 路由器没开 `maximum-paths`(FRR 默认 `multipath-relax` 关,需手动开)
- 只有一个节点宣告(检查 `externalTrafficPolicy` + ingress DS 是否真的多节点跑了)

### 4. LB 分配器日志

```bash
kubectl -n kube-system logs deploy/lb-assigner -f
```

### 5. 端到端连通

```bash
bash ../test-connectivity.sh

# 从集群外打 LB IP,验证 ingress 接到
curl -H "Host: <你的 ingress 域名>" http://172.16.150.200/

# 多发几次看是否均衡到不同节点(看 ingress pod 日志)
for i in {1..20}; do curl -s -H "Host: ..." http://172.16.150.200/; done
kubectl -n ingress-nginx logs ds/ingress-nginx-controller --tail=50 | grep <client_ip>
```

---

## 踩坑

| 现象 | 原因 | 修法 |
|---|---|---|
| LB Service EXTERNAL-IP `<pending>` | `lb-assigner` 没起来 / `--lb-cidr` 池满 | `kubectl -n kube-system get pod -l app=lb-assigner` + 看日志 |
| 路由器 `ip route show <LB_IP>` 只 1 个 nexthop | 路由器没开 ECMP / `multipath-relax` | FRR: `bgp bestpath as-path multipath-relax` + `maximum-paths <N>` |
| 只有 1 个节点在宣告 LB IP | `externalTrafficPolicy: Local` 但只有 1 个节点有 backend Pod | 把 ingress DS 调度到 ≥2 个节点(`nodeSelector` + `--label-nodes`) |
| BGP peer `Active` 不 `Established` | Calico 侧没配 BGPPeer / AS 不匹配 | `kubectl get bgppeer -o yaml` 看 AS;确认 `--peer-asn` 跟路由器一致 |
| namespace 卡 Terminating | `uninstall` 脚本 `python3` 不可用 | 手动:`kubectl get ns <N> -o json \| sed 's/"finalizers":\[[^]]*\]/"finalizers":[]/' \| kubectl replace --raw "/api/v1/namespaces/<N>/finalize" -f -`(或见 `k8s-cleanup-stuck` skill) |
| `Bad peer AS` | 路由器 AS 跟 Calico 配的不匹配 | 确认 `--peer-asn` 跟路由器实际 AS 一致 |
| ECMP 流量不均衡 | 路由器哈希算法只用 `src_ip`(默认 3-tuple) | 改 5-tuple:`ip rule + fib_multipath_hash_policy=1`(L3+L4) |

---

## 路由器侧 FRR ECMP 配置(参考)

如果你的"路由器"也是 FRR(本仓库测试环境就是),关键配置:

```
router bgp 64500
 bgp router-id 172.16.150.131
 bgp bestpath as-path multipath-relax
 maximum-paths 4
 neighbor 172.16.150.129 remote-as 64500    ! node1
 neighbor 172.16.150.130 remote-as 64500    ! node2
 ! ...
```

Linux 内核侧打开 L4 哈希(否则 ECMP 按 src_ip 哈希,单源压测时全到一个节点):

```bash
sysctl -w net.ipv4.fib_multipath_hash_policy=1   # 0=L3(默认), 1=L3+L4
```
