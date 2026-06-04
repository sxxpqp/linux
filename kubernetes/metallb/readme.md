# MetalLB

裸金属 / 自建 K8s 集群上提供 `Service.type=LoadBalancer` 实现。生产推荐。

## 文件

| 文件 | 状态 | 说明 |
|---|---|---|
| [install.sh](install.sh) | ✅ | L2 模式安装(kube-proxy 不在时自动跳过 strictARP) |
| [install-bgp.sh](install-bgp.sh) | ✅ | BGP 模式安装(需 --my-asn / --peer-asn / --peer-address) |
| [uninstall.sh](uninstall.sh) | ✅ | 卸载(默认 dry-run, --apply 真删) |
| [pool.yaml](pool.yaml) | ✅ | IP 池 + L2Advertisement |
| [bgp.yaml](bgp.yaml) | 参考 | BGP 配置模板(BGPPeer + BGPAdvertisement) |
| [metallb-native.yaml](metallb-native.yaml) | 离线 | 预下载上游清单(Nexus 不通时用) |

## L2 模式安装(默认)

```bash
bash install.sh
# 装完后任意 Service type=LoadBalancer 即可拿到 172.16.150.200-210 段 IP
```

## BGP 模式安装(生产推荐)

```bash
bash install-bgp.sh \
  --my-asn=64500 \
  --peer-asn=64501 \
  --peer-address=172.16.150.1
```

**架构**:
```
Internet → 路由器(ECMP) → node1/2/3 → ingress-nginx(hostNetwork:80) → Service → Pod
              ↑ BGP peer ↑
              └── 3 个节点都跟路由器跑 BGP, LoadBalancer IP 通过 ECMP 直达到目标节点
```

**路由器侧只需 3 行**(install-bgp.sh 会自动打印):
```
router bgp 64501
  neighbor 172.16.150.128 remote-as 64500
  neighbor 172.16.150.129 remote-as 64500
  neighbor 172.16.150.130 remote-as 64500
```

## 常见坑

- **strictARP 必须改**: L2 模式下 kube-proxy IPVS 默认代答 ARP,会跟 MetalLB speaker 抢答导致 VIP 抖动。`install.sh` 自动 patch,自己手动装的也要改。
- **IP 池必须跟节点同段**: L2 模式靠 ARP 广播,池子 IP 跟节点不同段交换机不会转发。BGP 模式可以跨段。
- **国内拉镜像**: MetalLB 镜像在 `quay.io/metallb/`,quay 国内可能慢。可以本地拉好 push 到内网 mirror,改 native 清单里的 image。
- **跟 kube-vip 共存**: 控制面 VIP 留 kube-vip 没问题,但要把 kube-vip DaemonSet 的 `svc_enable=false`,避免两个组件同时给 Service 分 IP。
