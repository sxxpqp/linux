# Calico BGP + 内置 LoadBalancer

> Calico BIRD 一套 BGP **同时宣告 Pod CIDR + LoadBalancer Service IP**,
> 不再需要 MetalLB / kube-vip 单独宣告 Service IP。

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

## 跟 bgp/ 目录的区别

| | bgp/ | bgp-lb/ |
|---|---|---|
| Pod CIDR 宣告 | ✅ | ✅ |
| LoadBalancer Service IP 宣告 | ❌ (需 MetalLB) | ✅ (Calico 自带) |
| BGPConfiguration | asNumber + nodeMesh | asNumber + nodeMesh + **serviceLoadBalancerIPs** |
| `--lb-cidr` 参数 | 无 | **必填** |

## TL;DR

```bash
# 安装
bash install.sh --apiserver-host=172.16.150.128 --my-asn=64500 \
  --lb-cidr=172.16.150.200/29

# 创建 LoadBalancer Service(外部可直接访问)
kubectl expose deploy nginx --port=80 --type=LoadBalancer \
  --overrides='{"spec":{"loadBalancerIP":"172.16.150.200"}}'

# 验证 — 外部访问 LB IP
curl http://172.16.150.200

# 卸载
bash uninstall.sh --apply
```

## IP 段规划

| 段 | 用途 |
|---|---|
| `172.16.150.128/25` | 节点 IP |
| `172.16.150.200/29` | **LoadBalancer Service IP**(8 个: .200-.207) |
| `10.244.0.0/16` | Pod CIDR |
| `10.96.0.0/12` | ClusterIP Service CIDR(kubeadm 默认) |

⚠ LB CIDR 必须跟节点同段(BGP neighbor 在同一个广播域), 但不能跟任何节点 IP 重叠。

## 跟 MetalLB 的区别

| | MetalLB BGP | Calico BGP-LB |
|---|---|---|
| 额外组件 | speaker DaemonSet | 无(复用 calico-node bird) |
| 资源占用 | +1 pod/node | 0 额外 |
| 配置 | IPAddressPool + BGPPeer + BGPAdvertisement | BGPConfiguration.serviceLoadBalancerIPs |
| LB IP 分配 | 自动 | 手动指定 loadBalancerIP |
