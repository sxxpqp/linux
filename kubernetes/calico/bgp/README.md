# Calico BGP 模式

> BGP 直连路由, 不封包, 跟上游路由器 peer 后外部可直连 Pod IP。

跟默认 BPF 模式区别:

| | BGP | BPF (operator) |
|---|---|---|
| dataplane | Iptables | eBPF |
| 跨节点 | BIRD BGP 路由 | VXLAN 封包 |
| kube-proxy | 保留(ClusterIP NAT) | 替换掉 |
| 内核要求 | 无特殊要求 | 5.3+ |
| 路由器 | 需要配 BGP neighbor | 不需要 |

## TL;DR

```bash
# 只开 node mesh(默认, 路由器 peer 后面再加)
bash install.sh --apiserver-host=172.16.150.128 --my-asn=64500

# 一步到位(含上游路由器 peer)
bash install.sh --apiserver-host=172.16.150.128 --my-asn=64500 \
  --peer-asn=64501 --peer-address=172.16.150.1

# 卸载
bash uninstall.sh --apply
```

## 文件

| 文件 | 状态 | 说明 |
|---|---|---|
| [install.sh](install.sh) | ✅ | BGP 安装: operator + BGPConfiguration + BGPPeer(可选) |
| [uninstall.sh](uninstall.sh) | ✅ | 卸载: 剥 CR finalizer + 清 namespace, 默认 dry-run |
| [installation.yaml](installation.yaml) | ✅ | Installation CR: Iptables + BGP + 无 VXLAN |

## 路由器侧配置

安装脚本会自动打印。配好后 BIRD 状态从 `Start` 变 `Established`:

```
router bgp 64501
  neighbor 172.16.150.128 remote-as 64500
  neighbor 172.16.150.129 remote-as 64500
  neighbor 172.16.150.130 remote-as 64500
```

## 验证

```bash
# BGP 配置
kubectl get bgppeer,bgpconfiguration,ippools

# BIRD BGP session(要有 Established)
kubectl -n calico-system exec ds/calico-node -- birdcl show protocols

# 连通性
bash ../test-connectivity.sh
```

## 之后加/改路由器 peer

```bash
kubectl apply -f - <<EOF
apiVersion: crd.projectcalico.org/v1
kind: BGPPeer
metadata:
  name: upstream-router
spec:
  peerIP: <ROUTER_IP>
  asNumber: <ROUTER_ASN>
EOF
```

## 踩坑

| 现象 | 原因 | 修法 |
|---|---|---|
| BIRD 没有 Established | 路由器没配 BGP neighbor 或 peer IP/ASN 不对 | 检查路由器 `show bgp summary`, 确认 peer 地址可 ping |
| kube-proxy 不在导致 ClusterIP 不通 | BGP 模式需要 kube-proxy | `kubeadm init phase addon kube-proxy` |
| namespace 卡 Terminating | 卸载后 metrics-server API 过期导致 ns 清理失败 | 重启 metrics-server 或手动 `kubectl delete ns --force` |
