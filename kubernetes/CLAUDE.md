# Kubernetes — AI 协作上下文

> 完整索引见 [README.md](README.md), 这里是 Claude 快速上下文。

## 集群参数(每次操作都要用)

| 项 | 值 |
|---|---|
| 节点 | kh `.128` node1 `.129` node2 `.130` node4 `.131` |
| Pod CIDR | `10.244.0.0/16` |
| Service CIDR | `10.96.0.0/12` |
| Calico 默认 | **operator BPF**(kube-proxy 已替换) |
| BGP AS | `64500` (iBGP) |
| LB CIDR | `172.16.150.200/29` |
| 路由器 peer | `172.16.150.131 AS 64500` |

## 常用命令(已测试参数, 直接 copy)

```bash
# Calico BPF 安装
bash kubernetes/calico/onpremises/operator/install.sh \
  --apiserver-host=172.16.150.128 --delete-kube-proxy

# Calico BGP-LB 安装(生产推荐)
bash kubernetes/calico/bgp-lb/install.sh \
  --apiserver-host=172.16.150.128 --my-asn=64500 \
  --lb-cidr=172.16.150.200/29 --peer-asn=64500 --peer-address=172.16.150.131

# 网络验证
bash kubernetes/calico/test-connectivity.sh

# ingress-nginx 安装
bash kubernetes/ingress-nginx/install.sh --label-nodes=node1,node2

# 卸载(都默认 dry-run, 加 --apply 才真删)
bash kubernetes/calico/onpremises/operator/uninstall.sh --apply
bash kubernetes/calico/bgp-lb/uninstall.sh --apply
bash kubernetes/ingress-nginx/uninstall.sh --apply
```

## 操作顺序(必读)

1. 先 `Read` 对应目录的 README.md
2. 再到对应目录跑 `install.sh` / `uninstall.sh`
3. 跑完用 `test-connectivity.sh` 或 `test.sh` 验证
