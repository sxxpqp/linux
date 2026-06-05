# Kubernetes — AI 协作上下文

> 先读 [README.md](README.md) 定位到子目录，再读子目录自己的 README。

## 当前集群状态

| 项 | 值 |
|---|---|
| 节点 | kh(172.16.150.128), node1(172.16.150.129), node2(172.16.150.130), node4(172.16.150.131) |
| Pod CIDR | 10.244.0.0/16 |
| Service CIDR | 10.96.0.0/12 |
| Calico 默认模式 | operator BPF(kube-proxy 已替换) |
| BGP AS | 64500(iBGP, 所有节点同 AS) |
| LB CIDR | 172.16.150.200/29(Calico BGP-LB 模式) |
| 入口 | ingress-nginx DS+hostNetwork on node1(:80) |

## 关键路径

| 用途 | 路径 |
|---|---|
| Calico BPF 安装 | [calico/onpremises/operator/install.sh](calico/onpremises/operator/install.sh) |
| Calico BGP-LB 安装 | [calico/bgp-lb/install.sh](calico/bgp-lb/install.sh) |
| 连通性验证 | [calico/test-connectivity.sh](calico/test-connectivity.sh) |
| ingress-nginx 安装 | [ingress-nginx/install.sh](ingress-nginx/install.sh) |
| MetalLB 安装 | [metallb/install.sh](metallb/install.sh) |
| Calico BGP 切换 | [calico/switch-to-bgp.sh](calico/switch-to-bgp.sh) |

## 目录

| 目录 | 说明 |
|---|---|
| [calico/](calico/) | CNI — BPF / BGP / BGP-LB 三模式 |
| [ingress-nginx/](ingress-nginx/) | 入口控制器(DS+hostNetwork) |
| [metallb/](metallb/) | MetalLB(L2 + BGP) |
| [cert-manager/](cert-manager/) | 证书自动管理 |
| [prometheus/](prometheus/) | 监控(kube-prometheus) |
| [longhorn/](longhorn/) | 块存储 |
| [kubeblocks/](kubeblocks/) | 数据库 Operator |
| [jenkins/](jenkins/) | CI/CD |
| [etcd/](etcd/) | etcd 备份恢复 |
