# 裸金属 IDC 集群 ingress-nginx 入口负载均衡 —— 两方案对比

> 场景:7 节点裸金属 K8s 集群在 IDC 机房,公网 IP 现在落在**单台 nginx** 上(单点 + 没分流)。
> 目标:多 ingress 节点真分流 + 入口高可用,消除单点。
> 本文一篇写全两个方案,所有配置可直接照抄落地。

---

## 0. 一句话结论

| 你的情况                                                                                                                                                                                         | 选 | 为什么 |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -- | ------ |
| **性能排名(吞吐天花板)**:🥇 **方案二**(路由器 ECMP)≫ 🥈 **方案三**(LVS-NAT)> 🥉 **方案一**(HAProxy)。**要高性能直接上方案二**——它没有"汇聚单点",根因见第 6 节。 |    |        |

| 你的情况                                                | 选                                                   | 为什么 / 主要代价                                                                                     |
| ------------------------------------------------------- | ---------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| 有可控路由器、**要高性能 / 可扩展**               | **方案二**:公网放路由器 + Calico BGP-LB ECMP   | ASIC 线速 + 无汇聚单点 + 加节点线性扩;**代价:要花钱买/租支持 BGP 的路由器,且依赖机房配合**      |
| 路由器不可用、要**内核态高性能**                  | **方案三**:边缘 Keepalived + **LVS-NAT** | 内核态 L4,比 HAProxy 省 CPU;**DR 模式在此不适用(出口同设备),只能 NAT性能没有那么好;可观测性差** |
| 路由器不可用、要**运维简单 / 可观测 / 将来要 L7** | **方案一**:边缘 Keepalived + HAProxy           | 直观、stats 可观测、可切 L7/SSL 卸载;**用户态性能垫底,active 单台扛全量**                       |

(前提:ingress-nginx 已下沉到 K8s 节点(DaemonSet + hostNetwork),业务 nginx 路由配置就绪。)

---

## 1. 统一规划参数(三方案共用)

| 项                                    | 值                                                                                                                                                         |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 集群节点(`192.168.100.0/24`)        | master×3:k8smaster1 `.10` / k8smaster3 `.21` / k8smaster2 `.30`;worker×4:k8swork1 `.11` / k8swork2 `.12` / k8swork3 `.27` / k8swork4 `.28` |
| ingress 节点(打标签 `ingress=true`) | k8swork1 `.11`、k8swork2 `.12`(后续可扩 `.27`/`.28`);master 不承载入口流量                                                                         |
| ingress 部署形态                      | DaemonSet +`nodeSelector: ingress=true` + `hostNetwork: true`,节点直接 bind `:80/:443`                                                               |
| 边缘设备                              | nginx2(现有,持公网 IP)+ nginx2(新增),**双网卡**:eth0 公网侧 / eth1 内网 `192.168.100.x`                                                            |
| 边缘内网 IP                           | nginx2 =`192.168.100.32`,nginx1 = `192.168.100.xxx`                                                                                                   |
| 公网 IP                               | 116.211.238.197(你机房分配的那一个,全文用占位符)                                                                                                           |
| 集群 LB VIP 段(方案二)                | `192.168.100.200/29`(`.200–.207`,8 个;ingress 用 `.200`)                                                                                            |
| BGP ASN                               | 集群侧 `64512` / 路由器侧 `64513`(私有段 64512–65534)                                                                                                 |
| 路由器 BGP 邻居 IP                    | `192.168.100.25x`(机房上联路由器,示例占位)                                                                                                               |
| Pod CIDR                              | `10.244.0.0/16`                                                                                                                                          |

---

## 2. 三条全链路对照

```
方案一(负载在边缘 L4):
  client ──公网──> [公网VIP] nginx1/nginx2 (Keepalived主备)
                       │  HAProxy mode tcp / balance leastconn
                       ├──> k8swork1 .11:443 ┐
                       └──> k8swork2 .12:443 ┘ ingress-nginx(hostNetwork)→ svc → pod
  · 分流发生在:HAProxy → 多 ingress 节点
  · HA 靠:Keepalived VRRP(公网 IP 在两台边缘漂)
  · 真实客户端 IP:HAProxy send-proxy-v2 → ingress use-proxy-protocol

方案二(公网放路由器,负载在路由器 L3 ECMP):
  client ──公网──> [公网IP] 机房路由器(可控)
                       │  DNAT/路由 公网 → 192.168.100.200
                       │  同一台路由器 BGP ECMP 多 nexthop
                 192.168.100.200 (Service LoadBalancer)
                       ├──> k8swork1 .11 ┐
                       └──> k8swork2 .12 ┘ ingress-nginx(hostNetwork)→ svc → pod
  · 无边缘 nginx、无 proxy_protocol
  · 分流发生在:路由器 ECMP(内核级,按 5 元组 hash)
  · HA 靠:BGP 撤路由(节点挂自动剔除)+ 路由器自身 HA(先单机过渡 → 后期堆叠/双机热备)
  · 真实客户端 IP:externalTrafficPolicy: Local(client 直达节点,真实 IP 天然保留)

方案三(边缘 LVS-NAT,内核态 L4):
  client ──公网──> [公网VIP] nginx1/nginx2 (Keepalived主备 + IPVS)
                       │  IPVS NAT:DNAT 到 ingress 节点(内核态转发)
                       ├──> k8swork1 .11 ┐
                       └──> k8swork2 .12 ┘ ingress-nginx(hostNetwork)→ svc → pod
                       ↑  回包经边缘 un-NAT(节点默认网关=边缘,出口也在这)
  · 分流发生在:边缘 IPVS(内核态,比 HAProxy 省 CPU)
  · HA 靠:Keepalived VRRP + 管理 IPVS 表 + 探活后端
  · 真实客户端 IP:NAT 模式天然保留(后端看到 client 真实 IP,无需 proxy_protocol)
  · 注:DR 模式不用——出口网关在同一台边缘,DR"回包旁路"优势作废
```

---

## 3. 方案一 —— 边缘双机 Keepalived(VRRP)+ HAProxy 四层负载

**定位**:负载均衡和入口 HA **都在集群外完成**。集群内 ingress 纯 hostNetwork,Service 类型无所谓(边缘直连节点 `:443`)。**不依赖路由器 BGP**。

### 3.0 两种部署位置(先选,决定要不要碰现有网关)⭐

HAProxy 是**全代理**(不是 DNAT):它和 ingress 节点之间**新建一条连接**,源 IP = HAProxy 内网 IP,所以 **ingress 节点的回包是回给 HAProxy(同网段 L2 直达),不经节点默认网关**。这带来两种截然不同的部署位置:

| 部署位置 | 说明 | 要不要动现有网关/出口 |
|---|---|---|
| **A. 旁挂入站(✅ 推荐,尤其已有业务在跑)** | **新申请一个公网 IP** 绑到新 HAProxy 盒子,只做入站反代;ingress 节点默认网关**保持不变** | **完全不用**,3.9 跳过,其他业务零影响 |
| B. 替代现有网关 | HAProxy 盒子同时接管公网入口 + 内网出口网关 | 需做 3.9(出口 SNAT + 网关 VIP) |

> **场景判断**:你现在 K8s 其他业务在跑、出口网关不能动 → **选 A**。新公网 IP 给新 HAProxy 盒子(eth0 公网 + eth1 内网 `192.168.100.x`),**不开 `ip_forward`、不当网关、不做 SNAT**,纯代理。现有公网 IP / 网关 / 出口 SNAT / 其他业务**全部不动**。代价仅多一个公网 IP。
> LVS(方案三)做不到这点:它只改目的地址,回包必须经 director,**强制改节点默认网关**,会动到你现有出口——所以你这场景**不该用 LVS**。

### 3.1 前置确认(先做,否则白干)

VRRP 切换 = 同一个公网 IP 从 nginx1 的网卡"漂"到 nginx2 的网卡,靠**免费 ARP(gratuitous ARP)** 通告上联交换机更新 MAC 表。**机房如果锁了 MAC,漂移不生效。**

先问机房 / 自己验证:

| 检查                  | 命令 / 话术                                                                                                                                                                    |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 问机房                | "这个公网 IP 能不能在我两台设备之间做 VRRP 漂移?上联端口有没有做 IP-MAC 绑定 / port-security / 静态 ARP?"                                                                      |
| 自验免费 ARP 能否生效 | 在 nginx2 上临时:`ip addr add <PUBLIC_IP>/<掩码> dev eth0; arping -c 3 -U -I eth0 <PUBLIC_IP>`,然后从外部 `ping <PUBLIC_IP>` 看是否切到 nginx2;验证完 `ip addr del` 撤掉 |

**结论分支**:

- 机房**允许**漂移 → 方案一成立,继续。
- 机房**锁 MAC**(常见于云厂商裸金属 / 严格 IDC)→ 方案一不可行,直接走**方案二**(BGP 由路由器宣告,不靠 ARP 漂移),或用机房提供的"浮动 IP / 弹性 IP API"做切换。

### 3.2 为什么一个公网 IP 就够(跨网卡 VIP 机制)

每台边缘设备两块网卡:

```
            ┌──────────── nginx1 (MASTER) ────────────┐
公网交换机 ──┤ eth0(公网侧):平时【无 IP】              │
            │ eth1(内网侧):192.168.100.241/24 固定    │
            └──────────────────────────────────────────┘
                          ↕ VRRP 心跳走 eth1(内网 unicast)
            ┌──────────── nginx2 (BACKUP) ────────────┐
公网交换机 ──┤ eth0(公网侧):平时【无 IP】              │
            │ eth1(内网侧):192.168.100.242/24 固定    │
            └──────────────────────────────────────────┘

公网 VIP = <PUBLIC_IP>  ← keepalived 只把它加在【当前 master 的 eth0】上
```

要点:

1. **VRRP 选举 / 心跳**绑在**内网网卡 eth1**(有固定 IP),两台用 `unicast_peer` 互发心跳——公网侧完全不参与选举,所以 eth0 平时没地址也无所谓。
2. **VIP 加在哪**:`virtual_ipaddress { <PUBLIC_IP> dev eth0 }`,谁当 master 就把公网 IP 临时挂到谁的 eth0;故障时摘掉、对端挂上。
3. **eth0 无地址也能工作**:网卡 link up 就能收发,IP 由 keepalived 动态挂;master 上 eth0 一旦有 VIP,内核就替它应答 ARP 并发免费 ARP。
4. **一个公网 IP = 主备(active-passive)**:同时只有一台对外。真正的"负载均衡"发生在 master 上 HAProxy → 多个 ingress 节点这一跳,不受主备影响。(要边缘双活需 2 个公网 IP + DNS 轮询,这里用不上。)

### 3.3 Keepalived 配置

两台都装:`yum install -y keepalived` 或 `apt install -y keepalived`。

**nginx1(MASTER)`/etc/keepalived/keepalived.conf`**:

```conf
global_defs {
    router_id nginx1
    enable_script_security
    script_user root
}

# HAProxy 进程挂了就降优先级,把 VIP 让给对端
vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"   # 进程存活探测
    interval 2
    weight -40                             # 挂了 priority 100-40=60 < 90,触发切换
    fall 2
    rise 2
}

vrrp_instance VI_PUB {
    state MASTER
    interface eth1                         # ← 选举/心跳走内网网卡(有固定 IP)
    virtual_router_id 51                   # 两台必须一致;同网段内唯一
    priority 100                           # MASTER 高
    advert_int 1
    unicast_src_ip 192.168.100.241         # 本机内网 IP
    unicast_peer {
        192.168.100.242                    # 对端(nginx2)内网 IP
    }
    authentication {
        auth_type PASS
        auth_pass Edg3VrrP                  # 两台一致,自定义
    }
    virtual_ipaddress {
        <PUBLIC_IP>/<掩码>   dev eth0       # ← 入站:VIP 挂公网网卡;平时 eth0 无 IP
        192.168.100.254/24   dev eth1       # ← 出站:内网默认网关 VIP(K8s 节点用,详见 3.9)
    }
    track_script {
        chk_haproxy
    }
}
```

**nginx2(BACKUP)** 只改 3 处:

```conf
    router_id nginx2          # global_defs 里
    state BACKUP
    priority 90
    unicast_src_ip 192.168.100.242
    unicast_peer { 192.168.100.241 }
```

启动:`systemctl enable --now keepalived`。

> 内核需允许绑非本机 IP(HAProxy 绑 VIP 时):`echo 'net.ipv4.ip_nonlocal_bind=1' >> /etc/sysctl.conf && sysctl -p`。

### 3.4 HAProxy 配置

两台都装:`yum install -y haproxy` / `apt install -y haproxy`。两台**配置完全相同**(谁是 master 谁干活)。

`/etc/haproxy/haproxy.cfg`:

```conf
global
    log /dev/log local0
    maxconn 100000
    nbthread 4
    daemon

defaults
    mode tcp
    timeout connect 5s
    timeout client  50s
    timeout server  50s
    option  dontlognull
    retries 2

# ---------- HTTP :80 ----------
frontend ft_http
    bind *:80
    default_backend bk_ingress_http

backend bk_ingress_http
    balance leastconn
    # send-proxy-v2 把真实客户端 IP 透传给 ingress(配套 3.5)
    server k8swork1 192.168.100.11:80 check send-proxy-v2
    server k8swork2 192.168.100.12:80 check send-proxy-v2

# ---------- HTTPS :443(TLS 透传,ingress 终止)----------
frontend ft_https
    bind *:443
    default_backend bk_ingress_https

backend bk_ingress_https
    balance leastconn
    option ssl-hello-chk                 # 用 TLS ClientHello 探活后端
    server k8swork1 192.168.100.11:443 check send-proxy-v2
    server k8swork2 192.168.100.12:443 check send-proxy-v2

# ---------- 可选:状态页 ----------
listen stats
    mode http
    bind 192.168.100.241:9000            # 各机填自己内网 IP
    stats enable
    stats uri /
    stats refresh 5s
```

启动:`systemctl enable --now haproxy`。

> **关键**:HAProxy `mode tcp` 是**四层透传**,TLS 在 ingress-nginx 上终止(证书放 K8s Secret,不放边缘)。后端要扩节点,直接在 backend 加 `server` 行即可。

### 3.5 ingress-nginx 安装(方案一)

hostNetwork 模式,Service 只要 ClusterIP(边缘直连节点端口,不需要 LoadBalancer):

```bash
# 打标签 + 装
bash install.sh --label-nodes=k8swork1,k8swork2 --service-type=ClusterIP
```

**让 ingress 认 proxy-protocol**(收 HAProxy 的 `send-proxy-v2`,才能拿到真实客户端 IP),编辑 ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  use-proxy-protocol: "true"
  use-forwarded-headers: "true"
  compute-full-forwarded-for: "true"
```

```bash
kubectl -n ingress-nginx rollout restart ds/ingress-nginx-controller
```

> ⚠️ `use-proxy-protocol: "true"` 后,**所有**到达 ingress 的连接都必须带 proxy-protocol 头。即只能经 HAProxy 进,**不能再直接 `curl 节点IP:80`**(会握手失败)。测试要打公网 VIP。

### 3.6 TLS 变体(可选:边缘终止)

若想在边缘卸载 TLS(证书放 nginx/HAProxy):把 `ft_https` 改 `mode http` + `bind *:443 ssl crt /etc/haproxy/certs/site.pem`,后端走 `:80`。**默认不推荐**——证书分散到边缘、ingress 的 annotation/重定向能力用不上。保持 3.4 的 TCP 透传。

### 3.7 故障切换演示

```bash
# 在 master(nginx1)上停 HAProxy
systemctl stop haproxy
# 1~3s 后 VIP 应漂到 nginx2
ssh nginx2 'ip addr show eth0 | grep <PUBLIC_IP>'   # 应能看到 VIP
# 外部持续 curl,观察是否仅极短中断
```

### 3.8 优缺点

| ✅ 优点                                     | ❌ 缺点                                                    |
| ------------------------------------------- | ---------------------------------------------------------- |
| 不依赖机房路由器,半天上线                   | 边缘 active-passive,单台 master 扛全部流量(够用但不是双活) |
| 故障域清晰,排查直观(HAProxy stats 一目了然) | 多一跳(边缘→节点),时延略增                                |
| 后端加节点 = 改 backend 一行                | 依赖机房允许 ARP/MAC 漂移(前置确认)                        |
| 七层能力可选(需要时切 mode http)            | 边缘是有状态网元,需自己运维 keepalived/haproxy             |

**缺点细看(为什么性能垫底)**:

1. **用户态全代理,性能最低**:每条连接都要内核↔用户态拷贝 + HAProxy 进程上下文,高并发时 master 单台 **CPU 先到瓶颈**(几十万并发就吃满核);开 SSL 卸载/L7 更耗 CPU。
2. **active-passive,一半设备闲置**:VRRP 主备,平时只有 master 干活,backup 纯待命;**带宽/PPS 上限 = 单台机器**,想更快只能换更猛的单机(纵向扩,有天花板)。
3. **多一跳 + 必经瓶颈**:`client→边缘→节点`,边缘是所有流量的汇聚点,时延 +1 跳,边缘挂/打满 = 全站受影响。
4. **真实 IP 依赖 proxy_protocol**:开了 `use-proxy-protocol` 后,**不能再直连节点测试**(握手失败),排查方式受限。
5. **进 + 出双向都压在边缘**:边缘还要兼出口 SNAT(3.9),master 一台同时扛入站反代 + 出站 NAT 两个方向的带宽。
6. **依赖机房允许 ARP/MAC 漂移**(VRRP 前提);切换时出站长连接默认重置(除非上 conntrackd)。

### 3.9 内部服务器出口(egress SNAT + HA)—— ⚠️ 仅"部署位置 B"才需要

> **如果你选 3.0 的位置 A(旁挂入站 + 新公网 IP),整节跳过** —— HAProxy 全代理,回包走 L2 直达 HAProxy,不经节点默认网关,现有出口零改动。本节只针对"HAProxy 盒子替代现有网关"的位置 B。

位置 B 下,边缘双机不光管**入站**,还接管内网服务器**出公网**(拉镜像 / 调外部 API / NTP)。现状那台单 nginx 若同时也是出口 SNAT 网关,换成双机后这条要一起 HA,否则切换/上线时内网集体断网。

做法:**入站公网 VIP(eth0)+ 出站内网网关 VIP(eth1)绑同一个 VRRP 实例一起漂**(上面 3.3 的 `virtual_ipaddress` 已加 `192.168.100.254`)。

**1) 两台边缘开转发 + SNAT**(只有 master 持 VIP,故只有 master 真转发):

```bash
sysctl -w net.ipv4.ip_forward=1        # 写进 /etc/sysctl.conf 持久化
iptables -t nat -A POSTROUTING -s 192.168.100.0/24 ! -d 192.168.100.0/24 -o eth0 -j MASQUERADE
```

**2) K8s 节点默认路由指向内网网关 VIP `192.168.100.254`**:

```bash
ip route replace default via 192.168.100.254
# 持久化:改 netplan / ifcfg,网关填 192.168.100.254
```

> Pod 出站:Calico `natOutgoing: Enabled` 先把 pod IP SNAT 成节点 IP → 节点经 `192.168.100.254` → 边缘 MASQUERADE 成公网 IP 出去,链路通。
> **平滑迁移**:把 `192.168.100.254` 设成跟现网那台 nginx 的内网网关 IP 一致,节点默认路由就不用改。
> **长连接无缝切换(可选)**:默认 active→backup 切换时出站 NAT 会话会重置(多数场景可接受);要不断连用 `conntrackd` 在两台间同步 conntrack 表。

---

## 4. 方案二 —— 公网放路由器 + Calico BGP-LB(路由器 ECMP),无边缘 nginx

**定位**:公网 IP 配在**机房可控路由器**上,路由器 DNAT/路由到内网 LB VIP,再由**同一台路由器三层 ECMP** 分流(内核级、多节点真分流、零额外跳数)。Calico 的一个 BIRD 进程**同时宣告 Pod CIDR + LoadBalancer Service IP**,不需要 MetalLB。**不需要 nginx1/nginx2,也不需要 proxy_protocol。**

### 4.1 拓扑

```
                router (AS 64513)
              ╱       │        ╲      BGP peer 到每个 ingress 节点
   k8swork1 .11   k8swork2 .12  ...   (AS 64512)
        │              │
        └── ECMP 多路径 ──┘ 宣告 192.168.100.200/29(LB VIP)+ 10.244.0.0/16(Pod CIDR)

   Service(ingress-nginx) type=LoadBalancer → EXTERNAL-IP = 192.168.100.200
   路由器对 192.168.100.200/32 装多条等价 nexthop → 按 5 元组 hash 分流到多节点
```

### 4.2 装 Calico BGP-LB

```bash
bash ../calico/bgp-lb/install.sh \
  --apiserver-host=192.168.100.10 \
  --my-asn=64512 \
  --lb-cidr=192.168.100.200/29 \
  --peer-asn=64513 \
  --peer-address=<ROUTER_IP>
```

脚本会落以下两个 CR(此处完整贴出,便于核对 / 手工 apply):

**BGPConfiguration**(集群 AS + node mesh + LB/External IP 宣告):

```yaml
apiVersion: crd.projectcalico.org/v1
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: 64512
  nodeToNodeMeshEnabled: true
  serviceLoadBalancerIPs:
    - cidr: 192.168.100.200/29
  serviceExternalIPs:
    - cidr: 192.168.100.200/29
```

**BGPPeer**(指向机房上联路由器):

```yaml
apiVersion: crd.projectcalico.org/v1
kind: BGPPeer
metadata:
  name: upstream-router
spec:
  peerIP: <ROUTER_IP>
  asNumber: 64513
```

> 脚本还会在 `kube-system` 部署一个 `lb-assigner`,自动给 `type=LoadBalancer` 的 Service 从 `192.168.100.200/29` 里分配 EXTERNAL-IP(Calico 本身不自动分配 LB IP)。

### 4.3 ingress-nginx 安装(方案二)

```bash
bash install.sh --label-nodes=k8swork1,k8swork2 --service-type=LoadBalancer
```

Service 关键字段(`externalTrafficPolicy: Local`):

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.100.200       # 固定到 .200(也可由 lb-assigner 自动分)
  externalTrafficPolicy: Local          # 关键:保真实 IP + 只让有 ingress pod 的节点宣告 VIP
  ports:
    - name: http
      port: 80
      targetPort: 80
    - name: https
      port: 443
      targetPort: 443
```

**为什么 `externalTrafficPolicy: Local`**:

1. **保真实客户端 IP**:不做 SNAT,后端 pod 看到真实源 IP。
2. **配合 ECMP 正确收敛**:只有**实际跑着 ingress pod 的节点**才会把 `192.168.100.200` 的健康检查通过、才被路由器纳入 ECMP nexthop。节点 drain → pod 走 → 该节点退出 ECMP,流量不黑洞。

验证:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller    # EXTERNAL-IP 应为 192.168.100.200
```

### 4.4 路由器侧配置(通用 IOS-like 伪配)

对每个 ingress 节点建 BGP 邻居,并开 ECMP 多路径:

```
router bgp 64513
  bgp log-neighbor-changes
  maximum-paths 16                       ! ← 开 ECMP,允许多条等价路径
  neighbor 192.168.100.11 remote-as 64512
  neighbor 192.168.100.12 remote-as 64512
  ! 后续扩节点再加 .27 / .28
  address-family ipv4 unicast
    neighbor 192.168.100.11 activate
    neighbor 192.168.100.12 activate
```

关键点:

- `maximum-paths 16`:不开的话路由器只选一条最优路径 = 退化成单节点,**没有 ECMP 就没有真分流**。
- 路由器会收到 `192.168.100.200/32`(LB)和 `10.244.0.0/16`(Pod CIDR)的宣告。

### 4.5 公网 IP 放在路由器(无边缘 nginx)

**架构决定**:公网 IP 配在**机房可控路由器**的 WAN 口,路由器 DNAT/路由公网 → 内网 LB VIP `192.168.100.200`,再由同一台路由器 BGP ECMP 分流到多节点。**不需要 nginx1/nginx2,也不需要 proxy_protocol**——client 直达节点,后端 pod 直接看到真实公网源 IP,只靠 `externalTrafficPolicy: Local`。

路由器侧两条(IOS-like 伪配,接 4.4 的 BGP 段一起配):

```
! 1) 公网入站 DNAT 到内网 LB VIP(公网 IP 配在 WAN 口)
ip nat inside source static tcp 192.168.100.200 80  116.211.238.197 80
ip nat inside source static tcp 192.168.100.200 443 116.211.238.197 443
! 2) 或三层直路由(若机房允许公网段直接路由进内网,省 NAT):
!    ip route 116.211.238.197/32 192.168.100.200
```

**入口 HA —— 先单机,后期升双机**:

| 阶段        | 形态                                                                             | 单点情况                                                     |
| ----------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| 第一步(now) | **单台路由器** 持公网 IP + DNAT + BGP                                      | 路由器是单点;但已比"单台 nginx"强(后端多节点真分流),可作过渡 |
| 第二步      | **双路由器/防火墙 HA**:堆叠(IRF/iStack)或双机热备(VRRP/HRP),公网 IP 做 VIP | 入口无单点                                                   |

> 升双机时对集群侧的唯一影响:**堆叠/逻辑一台 → BGPPeer 配 1 条**(指堆叠管理 VIP);**双机独立(VRRP)→ BGPPeer 配 2 条**(分别指两台路由器)。ingress / Calico 其余配置不变。

### 4.6 故障切换演示

```bash
# drain 一个 ingress 节点
kubectl drain k8swork1 --ignore-daemonsets --delete-emptydir-data
# 该节点 ingress pod 走 → externalTrafficPolicy:Local 健康检查失败 → BGP 撤 .200 路由
# 路由器上观察 nexthop 从 2 条变 1 条
#   show ip route 192.168.100.200      ! 期望多 nexthop,drain 后少一个
# 恢复
kubectl uncordon k8swork1
```

### 4.7 优缺点

| ✅ 优点                                          | ❌ 缺点                                                |
| ------------------------------------------------ | ------------------------------------------------------ |
| 路由器内核级 ECMP,真·多节点同时分流             | 依赖机房路由器配合(BGP + maximum-paths)                |
| 加节点零改动(节点起 ingress pod 自动入 ECMP)     | BGP/ECMP 排障门槛高(birdcl / show ip route)            |
| 单 BIRD 进程同时管 Pod CIDR + LB IP,无需 MetalLB | ECMP 按 hash 分流,rehash 时长连接可能瞬断              |
| 与本仓库生产标准一致,可扩到几十节点;无边缘网元   | 入口 HA 取决于路由器(单台是单点,需升堆叠/双机热备消除) |
| 出站 egress 路由器原生做(它就是网关),无需额外搭  | BGP/ECMP 排障门槛高,需机房配合                         |

**缺点细看(主要是钱和依赖,不是性能)**:

1. **要花钱买/租设备**:需要一台**支持 BGP + ECMP(`maximum-paths`)的路由器或三层交换机**。带 BGP 的企业级设备不便宜;机房租用的上联设备通常**不开放给你配 BGP**,要自购或加钱租。**要消除入口单点还得再来一台做堆叠/双机热备 → 设备成本翻倍**,堆叠/HA 有的型号还要 license。
2. **依赖机房配合(可能也要钱)**:公网 IP 要能落到你的路由器(改公网线接入点 / 解除 IP-MAC 绑定),机房不一定配合,或按"增值服务"收费;跨团队/跨厂商协作周期长。
3. **BGP/ECMP 排障门槛高**:AS、路由收敛、`birdcl show protocols`、`show ip route` 多 nexthop——不是普通运维都会,出问题定位慢,强依赖网络工程能力。
4. **单机过渡期路由器是单点(且更致命)**:第一步单台路由器时,它挂 = **进 + 出全断**(因为它同时是入口和出口网关),比"单台 nginx"故障面更大。
5. **ECMP rehash 瞬断**:节点增减时 hash 桶重算,部分**长连接被重分到别的节点而瞬断**(除非路由器支持一致性哈希 / resilient ECMP)。
6. **改配置要碰核心网络设备**:动路由器影响面大,变更窗口/审批比改一台边缘 Linux 严格。

---

## 5. 方案三 —— 边缘 Keepalived + LVS-NAT(内核态 L4)

**定位**:边缘双机,**用内核态 IPVS 做 L4 转发**(比 HAProxy 用户态省 CPU)。Keepalived 一身二职:VRRP 做 VIP HA + 直接管理 IPVS 表 + 探活后端。**只用 NAT 模式**——DR 模式的"回包旁路 director"优势,在"出口网关也在这台 director"的拓扑下完全作废(回包反正要经它),白搭 DR 的 `lo:VIP`+arp 复杂度,故弃用 DR。

### 5.1 拓扑与前置

- 同方案一:公网 IP 作 VRRP VIP,边缘双机(这里是 LVS director,不跑 nginx/haproxy)。**ARP/MAC 漂移前提同 3.1**。
- 后端 = ingress 节点 `.11/.12` 的 `:80/:443`。
- **NAT 模式硬要求**:后端(ingress 节点)默认网关必须指向 director 的内网 VIP `192.168.100.254`(回包才能经 director un-NAT)——**正好和 3.9 的出口网关 VIP 复用同一个**,拓扑自洽。

### 5.2 安装

```bash
yum install -y ipvsadm keepalived          # 或 apt install -y ipvsadm keepalived
modprobe ip_vs ip_vs_wrr ip_vs_rr
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf && sysctl -p
```

### 5.3 Keepalived 配置(VRRP + IPVS virtual_server)

**MASTER**(`/etc/keepalived/keepalived.conf`):

```conf
vrrp_instance VI_PUB {
    state MASTER
    interface eth1
    virtual_router_id 51
    priority 100
    advert_int 1
    unicast_src_ip 192.168.100.241
    unicast_peer { 192.168.100.242 }
    authentication { auth_type PASS; auth_pass Edg3VrrP }
    virtual_ipaddress {
        <PUBLIC_IP>/<掩码>   dev eth0       # 入站 VIP
        192.168.100.254/24   dev eth1       # 出站 + LVS 回包网关 VIP(同 3.9)
    }
}

# ---- IPVS:NAT 模式,80/443 各一个 virtual_server ----
virtual_server <PUBLIC_IP> 443 {
    delay_loop 3
    lb_algo wrr                 # 加权轮询(wlc 也可)
    lb_kind NAT                 # ← NAT 模式(非 DR)
    protocol TCP
    real_server 192.168.100.11 443 { weight 1; TCP_CHECK { connect_timeout 3; connect_port 443 } }
    real_server 192.168.100.12 443 { weight 1; TCP_CHECK { connect_timeout 3; connect_port 443 } }
}
virtual_server <PUBLIC_IP> 80 {
    delay_loop 3
    lb_algo wrr
    lb_kind NAT
    protocol TCP
    real_server 192.168.100.11 80 { weight 1; TCP_CHECK { connect_timeout 3; connect_port 80 } }
    real_server 192.168.100.12 80 { weight 1; TCP_CHECK { connect_timeout 3; connect_port 80 } }
}
```

**BACKUP**:`state BACKUP` / `priority 90` / `unicast_src_ip`/`unicast_peer` 对调;`virtual_server` 段两台**完全相同**。启动:`systemctl enable --now keepalived`。

### 5.4 ingress-nginx 安装(方案三)

```bash
bash install.sh --label-nodes=k8swork1,k8swork2 --service-type=ClusterIP
```

**不需要 proxy_protocol**:NAT 模式 director 只改目的地址,源 IP 保留,后端直接看到真实 client IP(前提是回包经 director,已由"节点默认网关=`192.168.100.254`"保证)。

### 5.5 出口 egress

同 3.9(出口网关 VIP + MASQUERADE)。方案三里这条**和 LVS 回包路径天然共用**:节点默认网关本来就指 director,回包 un-NAT 和出站 SNAT 都在这一台完成。

### 5.6 验证

```bash
ipvsadm -Ln          # virtual server + real server + 各后端连接数 + 权重
ipvsadm -Lnc         # 活动连接明细
systemctl stop keepalived    # VIP + IPVS 表应漂到 backup
```

### 5.7 优缺点

| ✅ 优点                                            | ❌ 缺点                                                            |
| -------------------------------------------------- | ------------------------------------------------------------------ |
| 内核态 IPVS,比 HAProxy 省 CPU、并发能力强          | NAT 模式双向都过 director,**没有 DR 的回包旁路**,吞吐不如 DR |
| NAT 模式天然保留真实 client IP,无需 proxy_protocol | 可观测性差(只有 ipvsadm,无 stats 页)                               |
| 不依赖机房路由器,公网落边缘自己可控                | 纯 L4,不能 SSL 卸载 / Host 路由(ingress 已做 L7,影响小)            |
| keepalived 一体管 VRRP + IPVS + 探活               | 仍 active-passive 单点 + 多一跳 + 依赖 ARP 漂移                    |

**缺点细看**:

1. **NAT 模式 = 双向单点汇聚**:进站 DNAT、回包 un-NAT 都在 director,**director 单机扛进 + 出双向流量**;省了 HAProxy 的用户态开销(内核转发),但仍是 active 单台,**带宽上限 = 单机**,横向扩不了。
2. **DR 模式在此不可用**:出口网关与 director 同设备,DR 的回包旁路优势归零——所以拿不到 LVS 最强形态,只能退而求其次用 NAT。
3. **可观测性 / 健康检查弱**:只有 `ipvsadm -Ln` 看连接数,没有 HAProxy stats 那种 per-backend 延迟/错误率;探活靠 keepalived `TCP_CHECK`/`HTTP_GET`,粒度不如 HAProxy。
4. **纯 L4**:做不了 SSL 卸载、按 Host/路径分流、改 header(本场景 ingress 已做 L7,影响有限,但少了边缘兜底能力)。
5. **高并发要调内核**:`ip_vs_conn_tab_bits`、`nf_conntrack_max`、conntrack 表大小都要按量级调,有学习/调优成本。
6. **切换丢状态**:VRRP 切换时 IPVS 连接表 + conntrack 不同步,**长连接重置**(同方案一,可上 conntrackd 缓解,但 IPVS 同步更繁琐)。
7. **出口 SNAT 仍要自建**(同 3.9),边缘依旧是有状态网元要运维。

---

## 6. 并排 Trade-off 对比

| 维度                     | 方案一 HAProxy                       | 方案二 路由器 BGP ECMP                                    | 方案三 LVS-NAT                             |
| ------------------------ | ------------------------------------ | --------------------------------------------------------- | ------------------------------------------ |
| 负载层级 / 空间          | L4+L7,边缘**用户态**           | L3,路由器**ASIC/内核**                              | L4,边缘**内核态 IPVS**               |
| **性能档位(吞吐)** | 🥉 最低(用户态全代理)                | 🥇 最高(ASIC 线速)                                        | 🥈 中(内核态,比 HAProxy 省 CPU)            |
| **有无汇聚单点**   | 有(active 单台扛全量)                | **无**(流量直达多节点)                              | 有(active 单台扛全量)                      |
| 入口 HA 机制             | VRRP 主备                            | BGP 撤路由剔节点 + 路由器 HA(堆叠/双机热备)               | VRRP 主备 + keepalived 管 IPVS             |
| 客户端真实 IP            | send-proxy-v2 + proxy_protocol       | externalTrafficPolicy:Local                               | **NAT 天然保留**,无需 proxy_protocol |
| 是否依赖机房路由器       | ❌ 不依赖                            | ✅ 依赖**可控 BGP 路由器**                          | ❌ 不依赖                                  |
| 额外网络跳数             | +1(边缘→节点)                       | 0(公网→路由器→节点)                                     | +1(边缘→节点)                             |
| 横向扩展                 | 改 backend 一行;**纵向扩有顶** | **加节点线性扩**(无顶)                              | 改 real_server;**纵向扩有顶**        |
| 可观测性                 | 强(stats 页)                         | 中(birdcl / 路由表)                                       | 弱(仅 ipvsadm)                             |
| SSL 卸载 / L7 路由       | ✅ 可(切 mode http)                  | 不在此层(ingress 做 L7)                                   | ❌ 不能(纯 L4)                             |
| **设备 / 钱**      | 2 台边缘 + 公网 IP(现有,便宜)        | **要买/租支持 BGP 的路由器,HA 再翻倍 + 机房配合费** | 2 台边缘 + 公网 IP(现有,便宜)              |
| 单点风险                 | 边缘 active-passive 扛全量           | 后端无瓶颈;入口单点在路由器(升双机消除)                   | 边缘 active-passive 扛全量                 |
| 内部服务器出口(egress)   | **旁挂入站(位置A):零改现网关**;替代网关(位置B)才需 3.9 | **路由器原生**(它就是网关)                          | **强制**改节点默认网关(动现有出口)         |

> 每格依据:性能档位=转发位置(用户态 < 内核态 < ASIC)+ 有无汇聚单点;跳数=链路图实测路径;扩展性="加一个节点"实际改动量(方案二节点起 pod 自动入 ECMP,方案一/三受限于 active 单机带宽)。

---

## 7. 选型建议 + 落地路径

**按"要不要高性能 + 有没有可控路由器"二选一**:

- **要高性能 + 有(或愿意买)可控 BGP 路由器 → 方案二**。ASIC 线速 + 无汇聚单点 + 加节点线性扩,是性能天花板和裸金属生产标准。代价是设备钱 + 机房配合。
- **要高性能但路由器不可用/不想花钱 → 方案三(LVS-NAT)**。内核态 L4,榨干单台边缘性能,不依赖路由器;但仍是 active 单点(纵向扩有顶),可观测性弱。
- **不追求极致性能、要运维简单可观测/将来可能要 L7/SSL 卸载 → 方案一(HAProxy)**。stats 直观、能切七层;性能垫底但够大多数中小流量用。

> 一句话:**性能 方案二 ≫ 方案三 > 方案一;省钱省事 方案一/三(用现有边缘);最强且可扩 方案二(花钱买路由器)。**

**⭐ 已有业务在跑、出口网关不能动 → 方案一"旁挂入站"(部署位置 A,见 3.0)**:新申请一个公网 IP 给新 HAProxy 盒子,只做入站反代,**节点默认网关 / 现有出口 / 其他业务全部不动**,风险最低。代价仅多一个公网 IP。
> 为什么不是方案三:LVS-NAT 强制把节点默认网关改成 director,会动到你现有出口 —— 此场景**排除 LVS**。
> 后续要入口 HA:再加一台 HAProxy + keepalived(VIP 用这个新公网 IP),先单机后双机。

**方案二分两步走(入口 HA 渐进)**:

1. **第一步(now)**:公网 IP 配到路由器,装 Calico BGP-LB,ingress Service 切 `LoadBalancer`,路由器 DNAT + BGP ECMP。**单台路由器过渡**——已比"单台 nginx"强(后端多节点真分流),入口暂为单点。
2. **第二步**:路由器升 **堆叠(IRF/iStack)或双机热备(VRRP/HRP)**,公网 IP 做 VIP,入口单点消除。集群侧只需把 BGPPeer 从 1 条改 2 条(双机独立时)或不变(堆叠)。

**灰度 / 回滚**:先拿一个测试域名解析到公网 IP、验证 ECMP(`show ip route 192.168.100.200` 看多 nexthop),再全量。回滚:把公网 IP 临时切回原 nginx 设备即可,集群侧不动。

---

## 8. 验证清单

**方案一(HAProxy)**:

```bash
# 打公网 VIP(不能直连节点,因为开了 proxy-protocol)
curl -I -H 'Host: test.example.com' http://<PUBLIC_IP>
# HAProxy 分流 / 健康检查
echo "show stat" | socat stdio /run/haproxy/admin.sock        # 或看 :9000 stats 页
# VIP 漂移
systemctl stop haproxy && ssh nginx2 'ip addr show eth0 | grep <PUBLIC_IP>'
```

**方案二(路由器 ECMP)**:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller     # EXTERNAL-IP=192.168.100.200
kubectl -n calico-system exec ds/calico-node -- birdcl show protocols   # BGP Established
# 路由器侧(示例)
#   show ip route 192.168.100.200        ! 期望多 nexthop
kubectl drain k8swork1 --ignore-daemonsets --delete-emptydir-data       # 看 ECMP 收敛
kubectl uncordon k8swork1
```

**方案三(LVS-NAT)**:

```bash
# 打公网 VIP
curl -I -H 'Host: test.example.com' http://<PUBLIC_IP>
# 看 IPVS 转发表 + 各后端连接分布
ipvsadm -Ln          # virtual server + real server + 权重 + 连接数
ipvsadm -Lnc         # 活动连接明细
# 后端拿到的源 IP 应是 client 真实 IP(NAT 模式)
kubectl -n ingress-nginx logs ds/ingress-nginx-controller | tail   # 看 access log 源 IP
# VIP + IPVS 表漂移
systemctl stop keepalived && ssh nginx2 'ip addr show eth0 | grep <PUBLIC_IP>; ipvsadm -Ln'
```
