# Calico BGP-LB 生产部署指南

> 裸金属 K8s 高负载入口方案: Calico BGP + ingress-nginx(DS+hostNetwork) + 路由器 ECMP,
> 一套 BGP 同时宣告 Pod CIDR + LoadBalancer Service IP, 不再需要 MetalLB。

## 一、完整架构

```
                          Internet
                             │
                        ┌────┴────┐
                        │  DNS    │  A 记录 → 172.16.150.200
                        └────┬────┘
                             │
                     ┌───────┴───────┐
                     │    路由器      │
                     │  AS 64501     │  maximum-paths 16
                     │  BGP ECMP     │
                     └───┬───┬───┬───┘
         BGP peer ───────┘   │   └────── BGP peer
        宣告 Pod CIDR        │        宣告 LB IP
    (10.244.0.0/16)     │    (172.16.150.200/29)
                         │
         ┌───────────────┼───────────────┐
         │               │               │
      node1           node2           node3
  172.16.150.128  172.16.150.129  172.16.150.130
         │               │               │
   ┌─────┴─────┐   ┌─────┴─────┐   ┌─────┴─────┐
   │Calico BIRD│   │Calico BIRD│   │Calico BIRD│  ← 一套 BGP 宣告两种路由
   │ Pod CIDR  │   │ Pod CIDR  │   │ Pod CIDR  │
   │ LB IP     │   │ LB IP     │   │ LB IP     │
   └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
         │               │               │
   ┌─────┴─────┐   ┌─────┴─────┐   ┌─────┴─────┐
   │  ingress  │   │  ingress  │   │  ingress  │  ← DaemonSet + hostNetwork:80/443
   │  nginx    │   │  nginx    │   │  nginx    │
   └─────┬─────┘   └─────┬─────┘   └─────┬─────┘
         │               │               │
         └───────────────┼───────────────┘
                    Service → Pod
```

## 二、关键设计决策

### 2.1 为什么 ingress-nginx 用 DaemonSet + hostNetwork?

```
外部流量两种到达路径:

① curl 172.16.150.200 → 路由器 ECMP → 节点 → kube-proxy DNAT → ingress Pod → Service
② curl 172.16.150.128 → 直达 node1 的 ingress(hostNetwork:80) → Service
```

| 路径 | 跳数 | 源 IP 保留 | 适用 |
|---|---|---|---|
| ① 走 LB IP | 路由器→节点→kube-proxy→Pod | ❌ NAT 会丢 | 需要 ECMP 负载均衡 |
| ② 走节点 IP | 路由器→节点→Pod | ✅ 直达 | DNS 多 A 记录 |

**推荐生产用②** — 少一跳, 不丢源 IP。路由器已经通过 BGP 收到所有节点路由, DNS 配 3 个 A 记录或用一个外部 LB 做 DNS HA。

### 2.2 为什么 Calico BGP + MetalLB 可以省掉 MetalLB?

| 功能 | MetalLB | Calico BIRD | 结论 |
|---|---|---|---|
| 宣告 Pod CIDR | ❌ | ✅ `nodeToNodeMesh` | Calico 自带 |
| 宣告 LB Service IP | ✅ `BGPAdvertisement` | ✅ `serviceLoadBalancerIPs` | Calico 自带 |
| 分配 LB IP | ✅ `IPAddressPool` | lb-assigner(本 repo 提供) | 等价 |
| 额外 Pod | speaker DS(每个节点 1 个) | 无(复用 calico-node) | Calico 省资源 |

**Calico BIRD 一个进程同时宣告 Pod CIDR + LB IP, 少一套组件。**

### 2.3 LB IP 为什么可以跟节点 IP 同网段?

```
路由器路由表:
  172.16.150.0/24    → Local(LAN)              ← 子网路由, 匹配节点
  172.16.150.200/32  → 172.16.150.128(BGP)     ← 主机路由, 优先!
  172.16.150.201/32  → 172.16.150.129(BGP)
```

**BGP `/32` 主机路由优先级高于直连 `/24` 子网路由。** 同一个网段, 不同 IP, 不冲突。

## 三、IP 段规划

| 段 | 用途 | 规模 |
|---|---|---|
| `172.16.150.0/25` | 节点 IP(.1-.126) | 126 节点 |
| `172.16.150.128/27` | 节点 IP(.128-.158) | 30 节点(更安全) |
| `172.16.150.200/28` | **LB Service IP**(.200-.214) | 15 个 LB Service |
| `10.244.0.0/16` | Pod CIDR | 65536 个 /26 块 |
| `10.96.0.0/12` | ClusterIP Service CIDR | 永不宣告 |

**扩展建议:** LB IP 用 `/28`(14 个可用) 或 `/27`(30 个可用), 根据 Service 数量定。预留空间给将来。

## 四、安装

### 4.1 前置

```bash
# 1. 节点确保 kube-proxy 在跑(BGP 模式需要)
kubectl -n kube-system get ds kube-proxy

# 2. Calico BGP-LB 安装
bash install.sh \
  --apiserver-host=172.16.150.128 \
  --my-asn=64500 \
  --lb-cidr=172.16.150.200/28 \
  --peer-asn=64501 \
  --peer-address=172.16.150.1

# 3. 入口节点打标签 + 装 ingress-nginx
kubectl label node node1 node2 node3 ingress=true --overwrite
bash ../../ingress-nginx/install.sh --label-nodes=node1,node2,node3
```

### 4.2 路由器侧

```
router bgp 64501
  maximum-paths 16
  neighbor 172.16.150.128 remote-as 64500
  neighbor 172.16.150.129 remote-as 64500
  neighbor 172.16.150.130 remote-as 64500
```

### 4.3 验证

```bash
# Calico BGP
kubectl -n calico-system exec ds/calico-node -- birdcl show protocols
# 期望: 每个 peer Established

# 路由器 BGP
show bgp summary
# 期望: State = Established, PfxRcd > 0

# 路由器路由表
show bgp ipv4 unicast
# 期望: 看到 10.244.x.x/26(Pod CIDR) + 172.16.150.200/28(LB IP)

# 建 LB Service 测试
kubectl expose deploy nginx --port=80 --type=LoadBalancer
kubectl get svc nginx    # EXTERNAL-IP 应该自动分配
curl http://<LB_IP>:80   # 从外部测
```

## 五、扩展方案

### 5.1 小规模(< 20 节点)

**什么都不用改。** `nodeToNodeMeshEnabled: true` 全互联 BGP, 每个节点跟其他所有节点 peer。

```
node1 ←→ node2 ←→ node3
  ↕       ↕       ↕
node4 ←→ node5 ←→ node6
```

### 5.2 中规模(20-50 节点)

全互联 BGP session 数 = N*(N-1)/2, 50 节点 = 1225 条 session, 仍可控。只需:

```bash
# ingress 不要在全部节点跑, 只给入口节点打标签
kubectl label node node1 node2 node3 ingress=true

# LB IP 池扩大
bash install.sh ... --lb-cidr=172.16.150.192/27  # 30 个 LB IP
```

### 5.3 大规模(50-200 节点)

**开 Route Reflector** — 选 2-3 个节点做 RR, 其他节点只跟 RR peer:

```bash
# 1. 关 node mesh, 切换到 RR 模式
cat <<EOF | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: 64500
  nodeToNodeMeshEnabled: false     # ← 关全互联
  serviceLoadBalancerIPs:
    - cidr: 172.16.150.200/28
EOF

# 2. 标记 RR 节点
kubectl label node node1 node2 route-reflector=true

# 3. 创建 RR peer group
cat <<EOF | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: BGPPeer
metadata:
  name: rr-clients
spec:
  nodeSelector: "!route-reflector"   # 非 RR 节点
  peerSelector: "route-reflector"    # 只跟 RR 节点 peer
EOF

# 4. RR 之间保持全互联(互相同步路由)
cat <<EOF | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: BGPPeer
metadata:
  name: rr-mesh
spec:
  nodeSelector: "route-reflector"
  peerSelector: "route-reflector"
EOF
```

效果: 200 节点只产生 ~400 条 BGP session(每个节点 2 条 RR), 而不是 19900 条。

### 5.4 入口节点扩展

```bash
# 加新入口节点
kubectl label node node-N ingress=true
# ingress-nginx DS 自动调度 Pod 到新节点

# 路由器加 BGP neighbor
router bgp 64501
  neighbor <NEW_NODE_IP> remote-as 64500
```

新节点加入后 **路由器自动 ECMP 包含新节点**, 无需重启路由器的 BGP session(graceful restart)。

## 六、故障切换

### 6.1 节点挂

```
节点宕机 → BGP keepalive 超时(默认 30-90s) → 路由器撤掉该节点的路由
         → ECMP 自动重新 hash → 流量只走剩余节点
```

### 6.2 ingress Pod 挂

```
ingress Pod Crash → DaemonSet 自动重启 → kube-proxy 自动移除该 Pod 的 DNAT
```

### 6.3 路由器挂

```
主路由器挂 → 如果有双路由器 + VRRP/HSRP → 备路由器接管
          → Calico BGP session 重建 → 15-30 秒恢复
```

## 七、监控

```bash
# BGP session 状态(告警: Active/Idle 超过 1 分钟)
kubectl -n calico-system exec ds/calico-node -- birdcl show protocols | grep -v Established

# LB 分配器健康
kubectl -n kube-system logs deploy/lb-assigner --tail=5

# ingress 流量
kubectl -n ingress-nginx logs ds/ingress-nginx-controller | grep -c '200\|status'

# 路由器侧(如果有 SNMP/API)
show bgp summary          # BGP peer 状态
show ip route <LB_IP>     # ECMP 路径数
```

## 八、踩坑速查

| 现象 | 原因 | 修法 |
|---|---|---|
| BGP peer `Active` 不 `Established` | 路由器未配 neighbor / AS 号错 | 检查 `show bgp summary`, 确认 peer IP 可达 |
| LB Service EXTERNAL-IP `<pending>` | kube-proxy 不在 | `kubeadm init phase addon kube-proxy` |
| LB IP curl 不通 | iptables 规则没建 | `iptables -t nat -L KUBE-SVC-XXX` 确认有 DNAT, 没有则重启 kube-proxy |
| router 看到 LB IP 但 ping 不通 | 节点没有 ARP 应答该 IP | 确认 `serviceExternalIPs` 和 `serviceLoadBalancerIPs` 都配了 |
| 大量节点后 BIRD CPU 高 | node mesh 全互联 BGP session 太多 | 切换到 RR 模式 |
| 加节点后 ECMP 不包含新节点 | 路由器 BGP 路由更新慢 | 路由器 `clear ip bgp * soft in` 软重置 |
