# 裸金属 IDC 集群 ingress-nginx 入口负载均衡 —— 两方案对比

> 场景:7 节点裸金属 K8s 集群在 IDC 机房,公网 IP 现在落在**单台 nginx** 上(单点 + 没分流)。
> 目标:多 ingress 节点真分流 + 入口高可用,消除单点。
> 本文一篇写全两个方案,所有配置可直接照抄落地。

---

## 0. 一句话结论

| 你的情况 | 选 | 为什么 |
|---|---|---|
| 想最快上线、暂时不动机房路由器 | **方案一**:边缘 Keepalived + HAProxy | 纯集群外,不依赖 BGP,半天能上 |
| 要可扩展、内核级多路径、长期生产标准 | **方案二**:Calico BGP-LB + 路由器 ECMP | 真·多节点 L3 分流,加节点零改动 |
| 想两头好处都要 | **混合**:边缘 Keepalived 持公网 VIP + 内网 BGP ECMP | 见第 5 节 |

**推荐路径**:本周先上**方案一**保证业务可用,同期跟机房确认 BGP,随后平滑切到**方案二**做长期底座。两者可共存过渡。

---

## 1. 统一规划参数(两方案共用)

| 项 | 值 |
|---|---|
| 集群节点(`192.168.100.0/24`) | master×3:k8smaster1 `.10` / k8smaster3 `.21` / k8smaster2 `.30`;worker×4:k8swork1 `.11` / k8swork2 `.12` / k8swork3 `.27` / k8swork4 `.28` |
| ingress 节点(打标签 `ingress=true`) | k8swork1 `.11`、k8swork2 `.12`(后续可扩 `.27`/`.28`);master 不承载入口流量 |
| ingress 部署形态 | DaemonSet + `nodeSelector: ingress=true` + `hostNetwork: true`,节点直接 bind `:80/:443` |
| 边缘设备 | nginx1(现有,持公网 IP)+ nginx2(新增),**双网卡**:eth0 公网侧 / eth1 内网 `192.168.100.x` |
| 边缘内网 IP | nginx1 = `192.168.100.241`,nginx2 = `192.168.100.242`(示例,挑同段空闲值) |
| 公网 IP | `<PUBLIC_IP>`(你机房分配的那一个,全文用占位符) |
| 集群 LB VIP 段(方案二) | `192.168.100.200/29`(`.200–.207`,8 个;ingress 用 `.200`) |
| BGP ASN | 集群侧 `64512` / 路由器侧 `64513`(私有段 64512–65534) |
| 路由器 BGP 邻居 IP | `<ROUTER_IP>`(机房上联路由器,示例占位) |
| Pod CIDR | `10.244.0.0/16` |

---

## 2. 两条全链路对照

```
方案一(负载在边缘 L4):
  client ──公网──> [公网VIP] nginx1/nginx2 (Keepalived主备)
                       │  HAProxy mode tcp / balance leastconn
                       ├──> k8swork1 .11:443 ┐
                       └──> k8swork2 .12:443 ┘ ingress-nginx(hostNetwork)→ svc → pod
  · 分流发生在:HAProxy → 多 ingress 节点
  · HA 靠:Keepalived VRRP(公网 IP 在两台边缘漂)
  · 真实客户端 IP:HAProxy send-proxy-v2 → ingress use-proxy-protocol

方案二(负载在路由器 L3 ECMP):
  client ──公网──> [公网VIP] nginx1/nginx2 (Keepalived主备)
                       │  nginx stream 透传到内网 LB VIP
                       v
                 192.168.100.200 (Service LoadBalancer)
                       │  路由器 BGP ECMP 多 nexthop
                       ├──> k8swork1 .11 ┐
                       └──> k8swork2 .12 ┘ ingress-nginx(hostNetwork)→ svc → pod
  · 分流发生在:路由器 ECMP(内核级,按 5 元组 hash)
  · HA 靠:BGP 撤路由(节点挂自动剔除)+ 边缘 Keepalived(公网 IP)
  · 真实客户端 IP:externalTrafficPolicy: Local + 边缘 proxy_protocol
```

---

## 3. 方案一 —— 边缘双机 Keepalived(VRRP)+ HAProxy 四层负载

**定位**:负载均衡和入口 HA **都在集群外完成**。集群内 ingress 纯 hostNetwork,Service 类型无所谓(边缘直连节点 `:443`)。**不依赖路由器 BGP**。

### 3.1 前置确认(先做,否则白干)

VRRP 切换 = 同一个公网 IP 从 nginx1 的网卡"漂"到 nginx2 的网卡,靠**免费 ARP(gratuitous ARP)** 通告上联交换机更新 MAC 表。**机房如果锁了 MAC,漂移不生效。**

先问机房 / 自己验证:

| 检查 | 命令 / 话术 |
|---|---|
| 问机房 | "这个公网 IP 能不能在我两台设备之间做 VRRP 漂移?上联端口有没有做 IP-MAC 绑定 / port-security / 静态 ARP?" |
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
        <PUBLIC_IP>/<掩码> dev eth0         # ← VIP 挂到公网网卡;平时 eth0 无 IP
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

| ✅ 优点 | ❌ 缺点 |
|---|---|
| 不依赖机房路由器,半天上线 | 边缘 active-passive,单台 master 扛全部流量(够用但不是双活) |
| 故障域清晰,排查直观(HAProxy stats 一目了然) | 多一跳(边缘→节点),时延略增 |
| 后端加节点 = 改 backend 一行 | 依赖机房允许 ARP/MAC 漂移(前置确认) |
| 七层能力可选(需要时切 mode http) | 边缘是有状态网元,需自己运维 keepalived/haproxy |

---

## 4. 方案二 —— 集群内 Calico BGP-LB(路由器 ECMP)+ ingress LoadBalancer

**定位**:负载均衡在**路由器三层 ECMP** 完成(内核级、多节点真分流、零额外跳数)。Calico 的一个 BIRD 进程**同时宣告 Pod CIDR + LoadBalancer Service IP**,不需要 MetalLB。边缘只把公网流量收口到内网 LB VIP。

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

### 4.5 公网 IP 收口(边缘仍需 HA)

公网 IP 物理落在边缘网卡上,所以**边缘仍要 Keepalived 双机**(配置同 3.2 / 3.3,VIP=公网 IP)。区别是边缘 nginx 不再 L4 反代到一堆节点,而是 `stream` 透传到**唯一的内网 LB VIP** `192.168.100.200`:

`/etc/nginx/nginx.conf`(stream 块):

```nginx
stream {
    upstream ingress_lb {
        server 192.168.100.200:443;      # 内网 LB VIP,路由器 ECMP 自动分流到多节点
    }
    server {
        listen 443;
        proxy_pass ingress_lb;
        proxy_protocol on;               # 透传真实客户端 IP(ingress 侧开 use-proxy-protocol)
    }
    upstream ingress_lb_http {
        server 192.168.100.200:80;
    }
    server {
        listen 80;
        proxy_pass ingress_lb_http;
        proxy_protocol on;
    }
}
```

> **进阶替代(去掉边缘)**:若机房愿意把**公网 IP 段直接路由到集群**(在路由器上把公网 VIP 也用 BGP/静态指到 `192.168.100.200` 或直接让 LB CIDR 用公网段),则边缘 nginx 可省掉,流量直接公网→路由器 ECMP→节点。适用条件:你掌控路由器、且公网 IP 段允许这么路由。多数租用 IDC 给单个公网 IP 时仍保留边缘收口。

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

| ✅ 优点 | ❌ 缺点 |
|---|---|
| 路由器内核级 ECMP,真·多节点同时分流 | 依赖机房路由器配合(BGP + maximum-paths) |
| 加节点零改动(节点起 ingress pod 自动入 ECMP) | BGP/ECMP 排障门槛高(birdcl / show ip route) |
| 单 BIRD 进程同时管 Pod CIDR + LB IP,无需 MetalLB | ECMP 按 hash 分流,rehash 时长连接可能瞬断 |
| 与本仓库生产标准一致,可扩到几十节点 | 仍需边缘 Keepalived 收口公网 IP(除非路由器直路由公网段) |

---

## 5. 并排 Trade-off 对比

| 维度 | 方案一 Keepalived+HAProxy | 方案二 Calico BGP-LB + ECMP |
|---|---|---|
| 负载发生层级 | L4,在边缘 HAProxy | L3,在路由器 ECMP(内核转发) |
| 真·多节点同时分流 | ✅(HAProxy 向多节点轮询) | ✅(路由器多 nexthop hash) |
| 入口 HA 机制 | VRRP(公网 IP 主备漂移) | BGP 撤路由剔节点 + 边缘 VRRP |
| 故障收敛时间 | VRRP ~1–3s;后端探活 ~2× interval | BGP keepalive/holdtime,默认数秒(可调) |
| 客户端真实 IP | send-proxy-v2 + use-proxy-protocol | externalTrafficPolicy:Local + proxy_protocol |
| 是否依赖机房路由器 | ❌ 不依赖(只需允许 ARP 漂移) | ✅ 依赖(BGP peer + maximum-paths) |
| 额外网络跳数 | +1(边缘→节点) | 0(路由器直接转发到节点;边缘收口那跳仅公网→内网) |
| 横向扩展(加 ingress 节点) | 改 HAProxy backend 加一行 | 节点起 pod 自动入 ECMP + 路由器加 neighbor |
| 运维复杂度 | 低(进程级,stats 直观) | 中高(BGP/BIRD 概念 + 路由器协同) |
| 设备/IP 成本 | 2 台边缘 + 1 个公网 IP(现有) | 2 台边缘 + 1 个公网 IP + 1 段内网 LB VIP |
| 单点风险 | 边缘 active-passive,master 扛全量 | 流量直达多节点,无边缘瓶颈(边缘仅收口) |

> 每格依据:跳数=链路图实测路径;收敛时间=各协议默认计时器(VRRP advert_int=1s×fall;BGP holdtime 默认 90s 但 BFD/短计时可压到秒级);扩展性=两套"加一个节点"实际改动量。

---

## 6. 选型建议 + 落地路径

**明确推荐**:
- **长期底座 → 方案二**。理由:内核级 ECMP 无边缘瓶颈、加节点零改动、与集群生命周期绑定(pod 在哪流量到哪),是裸金属 K8s 的生产标准做法。
- **本周要上线 / 机房 BGP 还没落实 → 先方案一**。理由:不碰路由器,半天能上,故障域清晰。

**推荐分两步走**:
1. **第一步(now)**:上方案一,业务先可用、消单点。
2. **第二步(BGP 就绪后)**:装 Calico BGP-LB,把 ingress Service 切 `LoadBalancer`,边缘 HAProxy 的多后端改成 nginx stream 透传到 `192.168.100.200`(即 4.5)。**灰度**:先把一个测试域名的边缘后端指向 `.200` 验证 ECMP,再全量切。**回滚**:边缘配置切回 3.4 的 HAProxy 多后端即可,集群侧不用动。

**可选混合(两头好处)**:
- 边缘:Keepalived 持公网 VIP(方案一的入口 HA)。
- 内网:Calico BGP-LB + 路由器 ECMP(方案二的真分流)。
- 即边缘只做"公网 IP 高可用 + 收口",真正的多节点负载交给路由器 ECMP。**何时值得**:既要保留对公网 IP 的强控制(防火墙/限速/WAF 放边缘),又要内网无瓶颈分流——这是生产上最稳的组合,也就是第二步的最终形态。

---

## 7. 验证清单

**方案一**:
```bash
# 打公网 VIP(不能直连节点,因为开了 proxy-protocol)
curl -I -H 'Host: test.example.com' http://<PUBLIC_IP>
# HAProxy 分流 / 健康检查
echo "show stat" | socat stdio /run/haproxy/admin.sock        # 或看 :9000 stats 页
# VIP 漂移
systemctl stop haproxy && ssh nginx2 'ip addr show eth0 | grep <PUBLIC_IP>'
```

**方案二**:
```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller     # EXTERNAL-IP=192.168.100.200
kubectl -n calico-system exec ds/calico-node -- birdcl show protocols   # BGP Established
# 路由器侧(示例)
#   show ip route 192.168.100.200        ! 期望多 nexthop
kubectl drain k8swork1 --ignore-daemonsets --delete-emptydir-data       # 看 ECMP 收敛
kubectl uncordon k8swork1
```
