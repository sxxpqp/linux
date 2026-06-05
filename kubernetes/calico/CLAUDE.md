# Calico — AI 协作上下文

> 先读 [README.md](README.md) 选模式。

## 三种模式速查

| 模式 | 目录 | 一句话 |
|---|---|---|
| BPF(默认) | [onpremises/](onpremises/) | eBPF + VXLAN, 替换 kube-proxy |
| BGP | [bgp/](bgp/) | BIRD BGP 路由, 需要 MetalLB 宣告 Service IP |
| **BGP-LB(生产推荐)** | [bgp-lb/](bgp-lb/) | BIRD BGP + 内置 LB + 自动 IP 分配, 免 MetalLB |

## 关键文件

| 用途 | 路径 |
|---|---|
| 连通性验证 | [test-connectivity.sh](test-connectivity.sh) |
| BPF→BGP 迁移 | [switch-to-bgp.sh](switch-to-bgp.sh) |

## 测试集群 BGP 参数

```
AS=64500(iBGP), LB CIDR=172.16.150.200/29
路由器 peer=172.16.150.131:64500
```
