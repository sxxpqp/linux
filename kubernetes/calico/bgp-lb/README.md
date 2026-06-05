# Calico BGP + 内置 LoadBalancer

> Calico BIRD 一套 BGP **同时宣告 Pod CIDR + LoadBalancer Service IP**，
> 不再需要 MetalLB / kube-vip。LB IP 自动分配，建 Service 即用。

## 架构

```
                       ┌──────────┐
                       │  路由器   │
                       └──┬───┬──┘
          ┌───────────────┘   └───────────────┐
          │ Pod CIDR          LoadBalancer IP │
          │ (10.244.0.0/16)   (172.16.150.200)│
          └──────┬──────────────────┬─────────┘
                 │                  │
          Calico BIRD          Calico BIRD
          (同一个进程)          (同一个进程)
                 │                  │
          ┌──────┴──────┐    ┌──────┴──────┐
          │  Pod 互通    │    │  外部可直连  │
          │  (BGP 路由)  │    │  LB Service  │
          └─────────────┘    └─────────────┘
```

## 文件

| 文件 | 状态 | 说明 |
|---|---|---|
| [install.sh](install.sh) | ✅ | BGP 安装: operator + BGPConfiguration + BGPPeer + LB 自动分配器 |
| [uninstall.sh](uninstall.sh) | ✅ | 卸载: 剥 CR finalizer + 清 namespace, 默认 dry-run |
| [installation.yaml](installation.yaml) | ✅ | Installation CR: Iptables + BGP + 无 VXLAN |
| [lb-assigner.sh](lb-assigner.sh) | ✅ | LB IP 自动分配器(安装时自动部署为 Deployment) |
| [simulate-router.sh](simulate-router.sh) | ✅ | 外部路由器模拟(FRRouting Docker, 用于测试 BGP peering) |

## TL;DR

```bash
# 安装(BGP + 自动 LB)
bash install.sh --apiserver-host=172.16.150.128 --my-asn=64500 \
  --lb-cidr=172.16.150.200/29 \
  --peer-asn=64500 --peer-address=172.16.150.1

# 创建 Service(自动分配 LB IP, 不需要手动指定)
kubectl expose deploy nginx --port=80 --type=LoadBalancer
kubectl get svc nginx   # EXTERNAL-IP 自动填充

# 验证
curl http://<LB_IP>:80

# 卸载
bash uninstall.sh --apply
```

## 参数

| 参数 | 必填 | 说明 |
|---|---|---|
| `--apiserver-host` | ✅ | API server 地址 |
| `--my-asn` | ✅ | 集群 BGP AS 号(私有 AS 64512-65534) |
| `--lb-cidr` | ✅ | LoadBalancer Service IP 段 |
| `--peer-asn` | 可选 | 上游路由器 AS 号(不传只开 node mesh) |
| `--peer-address` | 可选 | 上游路由器 BGP IP |

## IP 段规划

| 段 | 用途 |
|---|---|
| `172.16.150.128/25` | 节点 IP |
| `172.16.150.200/29` | **LoadBalancer Service IP**(8 个) |
| `10.244.0.0/16` | Pod CIDR (BGP 宣告) |
| `10.96.0.0/12` | ClusterIP Service CIDR |

⚠ LB CIDR 跟节点同段不冲突 — BGP 宣告 `/32` 主机路由，优先级高于 `/24` 子网路由。

## 跟其他模式对比

| | BPF (operator) | BGP (bgp/) | **BGP-LB (bgp-lb/)** |
|---|---|---|---|
| dataplane | eBPF | Iptables | Iptables |
| Pod 路由 | VXLAN | BIRD BGP | BIRD BGP |
| Service LB | MetalLB | MetalLB | **Calico 自带** |
| LB IP 分配 | MetalLB 自动 | MetalLB 自动 | **lb-assigner 自动** |
| kube-proxy | 替换 | 保留 | 保留 |
| 额外组件 | 无 | MetalLB speaker | lb-assigner(1 个 pod) |

## 验证

```bash
# Calico BGP 状态
kubectl -n calico-system exec ds/calico-node -- birdcl show protocols

# BGP 路由
kubectl -n calico-system exec ds/calico-node -- birdcl show route

# LB 分配器日志
kubectl -n kube-system logs deploy/lb-assigner

# 连通性
bash ../test-connectivity.sh
curl http://<LB_IP>:80
```

## 踩坑

| 现象 | 原因 | 修法 |
|---|---|---|
| LB Service EXTERNAL-IP `<pending>` | kube-proxy 不在(lb-assigner 可分配 IP 但需要 kube-proxy 做 DNAT) | `kubeadm init phase addon kube-proxy` |
| BGP peer `Active` 不 `Established` | Calico 侧没配 BGPPeer | `kubectl apply` 加 BGPPeer 指向路由器 IP |
| namespace 卡 Terminating | uninstall 脚本 python3 不可用 | 手动: `kubectl get ns <N> -o json \| sed 's/"finalizers":\[[^]]*\]/"finalizers":[]/' \| kubectl replace --raw "/api/v1/namespaces/<N>/finalize" -f -` |
| `Bad peer AS` | 路由器 AS 跟 Calico AS 不匹配 | 确认 `--peer-asn` 跟路由器一致 |
