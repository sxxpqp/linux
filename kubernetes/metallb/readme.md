# MetalLB

裸金属 / 自建 K8s 集群上提供 `Service.type=LoadBalancer` 实现。生产推荐。

## 文件

| 文件 | 说明 |
|---|---|
| `install.sh` | 一键安装 (改 kube-proxy strictARP + apply native 清单 + apply pool) |
| `uninstall.sh` | 卸载 |
| `pool.yaml` | IP 池 + L2 通告 (默认 L2/ARP 模式) |
| `bgp.yaml` | BGP 模式配置 (二选一替代 L2) |
| `metallb-native.yaml` | (可选) 离线 / 国内场景预下载的上游清单, 同目录有就优先用 |

## 安装

```bash
bash install.sh                # 默认 v0.14.8 + L2 模式
bash install.sh --version v0.14.5
```

**国内直接用 Nexus 代理拉**（无需梯子）:

```bash
# 通过 Nexus raw-githubusercontent 代理下载 (版本对齐 install.sh)
curl -kLo metallb-native.yaml \
  https://nexus.ihome.sxxpqp.top:8443/metallb/metallb/v0.14.8/config/manifests/metallb-native.yaml

# 跟 install.sh 同目录, install.sh 会自动用本地的
bash install.sh
```

镜像如果也拉不到 (`quay.io/metallb/controller`, `quay.io/metallb/speaker`),用 sed 把 `metallb-native.yaml` 里的 image 替换成内网 mirror 后再 apply。

装完后任意 namespace 建一个 `type: LoadBalancer` Service 就能拿到 `172.16.150.200-210` 段的 IP。

## 改 IP 池

编辑 `pool.yaml`,重新 apply:
```bash
kubectl apply -f pool.yaml
```

## L2 → BGP 切换

```bash
kubectl delete l2advertisement default-l2 -n metallb-system
# 改 bgp.yaml 里的 ASN / peerAddress 为实际网络配置
kubectl apply -f bgp.yaml
```

## 常见坑

- **strictARP 必须改**: L2 模式下 kube-proxy IPVS 默认代答 ARP,会跟 MetalLB speaker 抢答导致 VIP 抖动。`install.sh` 自动 patch,自己手动装的也要改。
- **IP 池必须跟节点同段**: L2 模式靠 ARP 广播,池子 IP 跟节点不同段交换机不会转发。BGP 模式可以跨段。
- **国内拉镜像**: MetalLB 镜像在 `quay.io/metallb/`,quay 国内可能慢。可以本地拉好 push 到内网 mirror,改 native 清单里的 image。
- **跟 kube-vip 共存**: 控制面 VIP 留 kube-vip 没问题,但要把 kube-vip DaemonSet 的 `svc_enable=false`,避免两个组件同时给 Service 分 IP。
