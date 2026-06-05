# Calico — AI 协作上下文

> 完整文档见各子目录 README.md, 这里是 Claude 快速上下文。

## 三模式选型

| 模式 | 目录 | dataplane | kube-proxy | Service LB | 适用 |
|---|---|---|---|---|---|
| BPF | [onpremises/](onpremises/) | eBPF+VXLAN | 替换 | MetalLB | 默认,性能 |
| BGP | [bgp/](bgp/) | Iptables | 保留 | MetalLB | 路由器对接 |
| **BGP-LB** | [bgp-lb/](bgp-lb/) | Iptables | 保留 | **Calico 自带** | **生产推荐** |

## 已测试参数

```
BGP AS=64500(iBGP), LB CIDR=172.16.150.200/29
路由器 peer=172.16.150.131:64500
BGP 已用 FRRouting Docker 在 node4 模拟验证通过
```

## 关键脚本

| 用途 | 路径 |
|---|---|
| 网络验证(必跑) | [test-connectivity.sh](test-connectivity.sh) |
| BPF→BGP 迁移 | [switch-to-bgp.sh](switch-to-bgp.sh) |

## 验证命令

```bash
# BGP 状态
kubectl -n calico-system exec ds/calico-node -- birdcl show protocols

# BGP 路由
kubectl -n calico-system exec ds/calico-node -- birdcl show route

# LB 分配器日志
kubectl -n kube-system logs deploy/lb-assigner
```
