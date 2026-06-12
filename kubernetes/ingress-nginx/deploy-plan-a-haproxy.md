# 方案一 · 旁挂入站 落地方案(HAProxy + 新公网 IP,不影响现有业务)

> 目标:为 ingress-nginx 提供入口负载均衡 + 高可用,**完全不动现有公网 IP / 现有 nginx / 网关 / 出口 / 其他业务**。
> 选型依据:见 [lb-comparison.md](lb-comparison.md) 第 3 节(方案一 · 部署位置 A · 旁挂入站)。
> 实施风格:**先单机跑通 → 后期升双机 HA**;每一步都可独立验证,可回滚。

---

## 1. 核心思路(一句话)

新申请 1 个公网 IP,绑到 **新 HAProxy 盒子**,只做"公网入站 → ingress 节点"的反代。HAProxy 是**全代理**(新建到后端的连接,源 IP 是它自己的内网 IP),所以 **ingress 节点的回包走 L2 直达 HAProxy,不经默认网关** —— 现有出口/网关/其他业务**零感知**。

```
  现网(不动):
    其他业务 / K8s 出站 ──> 现有网关(原公网 IP 116.211.238.197)── 互联网

  新增(只入站):
    client ──<NEW_PUBLIC_IP>──> [HAProxy 盒子] ─192.168.100.x─> ingress 节点 .11/.12
                                  (mode tcp + send-proxy-v2)
                                  回包: ingress 节点 ─L2 直达─> HAProxy 盒子 (不经任何网关)
```

---

## 2. 容量规划 + IP 规划 + 服务器选型(开工前定下来)

### 2.1 高并发演进路径 ⭐(诚实交代天花板)

HAProxy 用户态、active-passive、单台扛全量,**性能档位在三方案里垫底**(详见 [lb-comparison.md §6](lb-comparison.md))。所以本方案定位是:**先用最小代价跑起来 + 把演进位置占好**,真要往高并发推时,平滑切到方案二(路由器 BGP ECMP)。

| 阶段 | 形态 | 目标量级(经验值,SSL 透传 `mode tcp`) | 单点 | 何时升下一阶段 |
|---|---|---|---|---|
| 0 现状 | 单 nginx | < 1 万 QPS | 边缘单点 | 立刻 |
| **1 本方案单机** | 单 HAProxy(本方案 §3–§6) | **≈ 5 万 QPS / 10 万并发 / 1 Gbps** | 边缘单点 | 业务稳定 / 流量上量 |
| **2 本方案双机 HA** | 双 HAProxy + Keepalived(§7) | 容量不变 ≈ 5 万 QPS(active-passive) | 已消除 | 流量超单机峰值 |
| **3 双活拉伸** | 加第 2 个公网 IP,两台 HAProxy 各持一个,DNS 轮询 | **≈ 10 万 QPS / 双台并行** | 已消除 | 流量继续上 / 要内核态/线速 |
| **4 切方案二** | 上可控 BGP 路由器,公网 IP 挪到路由器,Calico BGP-LB ECMP | **30 万+ QPS,加节点线性扩** | 路由器双机消除 | 终态 |

> **建议**:服务器选型按"阶段 2 撑得稳"取规格(看 §2.3);IP 规划按"阶段 4 也不用大改"占位(看 §2.4)。

### 2.2 性能经验值(单台 HAProxy,作为容量规划依据)

| 维度 | mode tcp(TLS 透传,推荐) | mode http(L7,SSL 终止) |
|---|---|---|
| CPU 经验值 | ≈ **2 万 QPS / 核** | ≈ 8 千 QPS / 核(SSL 终止吃 CPU) |
| 内存 | 每万并发 ≈ 30–60 MB | 每万并发 ≈ 100 MB |
| 网卡 PPS | 千兆 ≈ 14.8 万 PPS(线速极限) | 同 |
| 上限信号 | `top` `softirq` 高 / `ksoftirqd` 100% | CPU user 高 |

> **强烈建议本方案用 `mode tcp` 透传**:省 CPU、不碰证书、ingress 已经在做 L7。

### 2.3 服务器规格选型(按目标量级分档)

> 三档都按 **双网卡(公网 + 内网)** 配置;CPU 选**单核高主频** > 多核低主频(HAProxy 单连接路径短,主频比核数重要)。

| 档位 | 适配阶段 | CPU | 内存 | 网卡 | 适配 QPS / 并发 / 带宽 | 备注 |
|---|---|---|---|---|---|---|
| **入门 A** | 阶段 1 起步 | 4C / 3.0GHz+ | 8 GB | 2 × 1 GE | ≤ 5 万 / ≤ 10 万 / ≤ 1 Gbps | 物理机或虚机均可 |
| **标准 B(推荐起步)** | 阶段 1→2 长期 | **8C / 3.0GHz+** | **16 GB** | **2 × 10 GE** | ≤ 15–20 万 / ≤ 50 万 / ≤ 8 Gbps | 物理机优先,网卡用 Intel X710 / Mellanox CX-4 |
| **高档 C** | 撑到阶段 3 | 16C / 3.5GHz+ | 32 GB | 2 × 25 GE(SR-IOV / DPDK 可选) | ≤ 30–40 万 / ≤ 100 万 / ≤ 20 Gbps | 已接近 HAProxy 单机天花板,该考虑方案二 |

**不推荐**:虚机 + 低频 CPU(2.x GHz)+ 1Gbps 网卡 → 高并发下 PPS / 中断不够,先撞网卡瓶颈,不是 CPU。

**双机时**:两台规格**完全一致**(VRRP 主备同型号同配,避免切换后性能跳水)。

**容量留 headroom**:按预期峰值的 **2 倍**选规格,日常 < 50% 利用率,留升级/故障腾挪空间。

### 2.4 IP 规划(内外网一次性占好,演进不大改)⭐

#### 公网 IP

| 地址 | 用途 | 阶段 | 说明 |
|---|---|---|---|
| `116.211.238.197` | **现网** nginx,继续做现有出口 + 老业务入口 | 全程保留 | **不动** |
| `<NEW_PUBLIC_IP>` | **本方案新入口**,绑 HAProxy 盒子(单机)或漂在两台间(HA) | 阶段 1–2 | **新申请 1 个** |
| `<NEW_PUBLIC_IP_2>`(可选) | 阶段 3 双活拉伸第二个公网 IP | 阶段 3 才申请 | 同段更好,做 DNS 双 A 轮询 |
| 路由器 WAN IP / 公网段 | 阶段 4 公网入口挪到路由器 | 阶段 4 | 现网+新增 IP 可迁过去,无需多申请 |

#### 内网段 `192.168.100.0/24`(按段位划分,留够位置)

| IP 段 | 用途 | 现状 / 阶段 | 备注 |
|---|---|---|---|
| `.1` | **网关 / 后期路由器** | 现状是现 nginx 网关;阶段 4 路由器接入 | 保留 |
| `.2` | 阶段 4 路由器双机第二台 | 阶段 4 | 预留 |
| `.10` | k8smaster1 | 现状 | |
| `.11` `.12` | **k8swork1 / k8swork2(ingress 节点)** | 现状 | 打 `ingress=true` |
| `.21` | k8smaster3 | 现状 | |
| `.27` `.28` | k8swork3 / k8swork4 | 现状 | 后期可扩 ingress 标签 |
| `.30` | k8smaster2 | 现状 | |
| `.31–.39` | K8s 控制面 / worker 扩容预留 | — | |
| **`.32`** | **现网 nginx**(继续在跑,不动) | 现状 | 保留 |
| `.33–.39` | 现网 nginx 备机 / 其他基础设施预留 | — | |
| **`.41`** | **新 HAProxy 盒子 ①(本方案单机)** | **阶段 1** | eth1 管理 IP |
| **`.42`** | **新 HAProxy 盒子 ②(HA 第二台)** | **阶段 2** | eth1 管理 IP |
| `.43–.49` | 边缘 LB / 反代盒子扩容预留 | — | 避开 `.32` 段 |
| `.100–.199` | 业务虚机段(若有) | — | 与基础设施段隔离 |
| **`.200–.207`(/29)** | **阶段 4 K8s Service LoadBalancer VIP 段** | **预留**(对应 lb-comparison §1) | ingress 用 `.200` |
| `.208–.249` | 未来 LB VIP 扩容预留 | — | |
| `.250–.253` | 网络设备管理 IP / 出口设备 | — | |
| `.254` | 备用网关 VIP(替代网关形态用,本方案不用) | — | 占位别给业务用 |

#### VRRP `virtual_router_id` 规划(避免冲突)

| ID | 用途 |
|---|---|
| `71` | **本方案 HAProxy HA**(阶段 2) |
| 1–70 | 已用 / 留给现网 / 其他 VRRP | 别撞 |
| 72–99 | 未来其他 VRRP 实例预留 |

> **关键原则**:`.41/.42` 落在和 ingress 节点同段,这样回包走 L2 直达 HAProxy(本方案的核心);`.200/29` 提前留好,阶段 4 切方案二时 Calico BGP-LB CIDR 直接用,不动 IP 规划。

### 2.5 物料清单(按上面规划具体化)

| 项 | 数量 | 备注 |
|---|---|---|
| ☐ 新公网 IP `<NEW_PUBLIC_IP>` | 1 | 阶段 1 必需 |
| ☐ HAProxy 服务器(规格按 §2.3 标准档 B) | **阶段 1: 1 台;阶段 2: 2 台** | 双网卡 |
| ☐ 内网 IP `192.168.100.41`(阶段 2 再加 `.42`) | 1–2 | 按 §2.4 占位 |
| ☐ DNS 控制权(改业务域 A 记录) | — | 灰度必需 |
| ☐ 后期可控 BGP 路由器(阶段 4) | 1(后期 2 台) | **阶段 4 才采购**,本方案不阻塞 |

### 2.6 现有环境必须满足的条件

| 条件 | 验证命令 | 不满足后果 |
|---|---|---|
| ☐ ingress-nginx **还没装**(或 install.sh 还能重跑) | `kubectl get ns ingress-nginx` | 已装的话需评估 ConfigMap/Service 是否要改(见 §6.5) |
| ☐ ingress 节点 `:80 / :443` 物理可达 | 从 HAProxy 盒子 `nc -vz 192.168.100.11 443` | 不通则要排查防火墙/路由 |
| ☐ HAProxy 盒子内网网卡能 ping 通 ingress 节点 | `ping 192.168.100.11` | 同上 |
| ☐ 节点上 `:80 / :443` **未被占用** | 节点上 `ss -lntp \| grep -E ':80\|:443'` | 占用了 ingress hostNetwork 起不来 |
| ☐ ingress 节点 **未做 IP-MAC 绑定限制** 收外部连接 | 跨网段时常见 | 影响 HAProxy 反代 |
| ☐ K8s 节点默认网关、路由表、iptables **都不需要改** | `ip route; iptables -t nat -S` | 本方案天然零改动,先记录现状方便后续比对 |
| ☐ 内网交换机端口能承载 §2.3 选的网卡速率 | 看交换机端口型号 | 10GE HAProxy 接千兆口 = 浪费规格 |

### 2.7 机房 / 网络部门确认事项(发申请时一并问)

```
1) 新公网 IP 分配:能否分配 1 个独立公网 IP,不与现网 116.211.238.197 同 VLAN/子网也可
2) 接入方式:公网线接新 HAProxy 盒子 eth0 是独立直连还是与现网 nginx 共用接入交换机
3) 安全组/ACL:新公网 IP 默认放行 80/443 入站,其余 drop
4) 互不干扰确认:新公网 IP 故障不会影响 116.211.238.197 的可用性(双 IP 物理/逻辑独立)
5) [阶段 2 HA] 公网 IP <NEW_PUBLIC_IP> 是否允许在两台设备间做 ARP/MAC 漂移(VRRP 必需)
6) [阶段 3 双活] 是否可再申请第 2 个公网 IP,用于 DNS 双 A 轮询
7) [阶段 4 终态] 机房上联路由器能否做 BGP peering(为切方案二预热)
8) 内网交换机给 HAProxy 盒子提供端口的速率(必须匹配 §2.3 选的网卡)
```

---

## 3. 物理拓扑(单机阶段)

```
         INTERNET
            │
            │  <NEW_PUBLIC_IP>
            ▼
   ┌──────────────────────┐
   │ HAProxy 盒子 (新增)   │
   │ eth0: <NEW_PUBLIC_IP> │── 公网侧
   │ eth1: 192.168.100.41 │── 内网侧
   └──────────┬───────────┘
              │ 走内网交换机
     ┌────────┼────────┐
     ▼        ▼        ▼ (后续可扩 .27/.28)
  k8swork1  k8swork2
   .11       .12
   ingress-nginx (hostNetwork, :80/:443)

  ─── 现有链路(完全不动) ───
  其他业务 / 出站 ──> 现有网关(116.211.238.197) ── 互联网
```

**关键点(决定为什么"不影响现业务")**:
- HAProxy 盒子 eth1 内网 IP 和 ingress 节点 **同二层**,后端回包是 `ingress 节点 → 192.168.100.41`,**走 L2 直达,不经任何网关**。
- HAProxy 盒子**不开 `ip_forward`、不当网关、不做 SNAT** —— 它纯代理,不转发任何过路流量。
- K8s 节点默认网关、出口、其他业务的所有路径 **零改动**。

---

## 4. 实施步骤(单机阶段)

### 4.1 步骤 0:DNS 准备(灰度核心)

**先不要动主域名 A 记录**。准备一个**测试子域**(如 `test-ingress.example.com`)解析到 `<NEW_PUBLIC_IP>`,全流程验证通过后再切主域名。

### 4.2 步骤 1:HAProxy 盒子系统初始化

```bash
# 关 SELinux + firewalld(本盒子作为入口反代,iptables 后面单独管控)
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
systemctl disable --now firewalld

# 时间同步(配现场 NTP 或 chrony)
systemctl enable --now chronyd

# 内核参数(允许 bind 非本机 IP — 后期 VIP 用得着;关闭无用功能)
cat >>/etc/sysctl.conf <<'EOF'
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 10000 65000
EOF
sysctl -p

# 文件句柄
cat >>/etc/security/limits.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF
```

> **注意**:**绝对不要** `echo 'net.ipv4.ip_forward=1'`。这台盒子不当网关,开了反而可能引入意外的转发路径。

### 4.3 步骤 2:网卡配置(双网卡,公网+内网)

按 OS 改 ifcfg / netplan,示例:

```ini
# eth0 公网
DEVICE=eth0
BOOTPROTO=static
IPADDR=<NEW_PUBLIC_IP>
NETMASK=<NEW_PUBLIC_MASK>
GATEWAY=<NEW_PUBLIC_GATEWAY>     # ← 默认路由走公网网关(出 HAProxy 自身管理流量)
ONBOOT=yes

# eth1 内网
DEVICE=eth1
BOOTPROTO=static
IPADDR=192.168.100.41
NETMASK=255.255.255.0
# !!! 不要在 eth1 配 GATEWAY !!!,只配 IP,默认路由走 eth0
ONBOOT=yes
```

**坑①(常见)**:双网卡两个 GATEWAY 会导致路由不可预测。**只在 eth0 配默认网关**,内网走 eth1 的同段直连路由即可。如果有跨网段访问需求,在 eth1 上加静态路由(`192.168.0.0/16 via 192.168.100.x`)。

**验证**:

```bash
ip route       # 默认路由应只有一条,走 eth0
ping -c 2 192.168.100.11      # 内网到 ingress 节点
ping -c 2 8.8.8.8             # 公网出
```

### 4.4 步骤 3:装 HAProxy + Keepalived(Keepalived 第二阶段才启用)

```bash
yum install -y haproxy keepalived socat   # CentOS/RHEL
# 或:apt install -y haproxy keepalived socat

systemctl enable haproxy
# 注意:keepalived 这一步不要 enable,单机阶段不需要,留给第二阶段
```

### 4.5 步骤 4:HAProxy 配置(单机版)

`/etc/haproxy/haproxy.cfg`:

```conf
global
    log /dev/log local0
    maxconn 200000
    nbthread 4
    daemon
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s

defaults
    mode tcp
    timeout connect 5s
    timeout client  60s
    timeout server  60s
    option  dontlognull
    retries 2
    log     global

# ===== HTTP :80 =====
frontend ft_http
    bind <NEW_PUBLIC_IP>:80
    default_backend bk_ingress_http

backend bk_ingress_http
    balance leastconn
    option httpchk GET / HTTP/1.0
    http-check expect status 404           # ingress 根路径默认 404,作为存活信号
    server k8swork1 192.168.100.11:80 check send-proxy-v2
    server k8swork2 192.168.100.12:80 check send-proxy-v2

# ===== HTTPS :443(TLS 透传)=====
frontend ft_https
    bind <NEW_PUBLIC_IP>:443
    default_backend bk_ingress_https

backend bk_ingress_https
    balance leastconn
    option ssl-hello-chk
    server k8swork1 192.168.100.11:443 check send-proxy-v2
    server k8swork2 192.168.100.12:443 check send-proxy-v2

# ===== 本地状态页(只绑内网,公网不暴露)=====
listen stats
    mode http
    bind 192.168.100.41:9000
    stats enable
    stats uri /
    stats refresh 5s
    stats auth admin:<CHANGE_ME_STRONG_PASSWORD>
```

**重点解释**:
- `bind <NEW_PUBLIC_IP>:80/443` —— 显式绑新公网 IP,避免一不小心绑到 `*` 把内网 9000 端口暴露。
- `send-proxy-v2` —— 把真实客户端 IP 透传给 ingress,**必须**配合 4.7 步的 ConfigMap。
- `option httpchk` + `expect status 404` —— ingress-nginx 根路径默认 404 也算"活着",比 `option tcp-check` 更准。
- `stats` 绑内网 IP + 强密码 —— **绝对不要绑 `0.0.0.0`**,否则状态页公网可访问。

启动:

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg     # 先校验配置语法
systemctl start haproxy
systemctl status haproxy
ss -lntp | grep haproxy                    # 应看到 :80 :443 :9000 监听
```

### 4.6 步骤 5:装 ingress-nginx(只装一次,只打两个节点标签)

```bash
# 标签 + 装(Service 用 ClusterIP,因为入站直接走节点 hostNetwork)
bash kubernetes/ingress-nginx/install.sh \
  --label-nodes=k8swork1,k8swork2 \
  --service-type=ClusterIP
```

验证:

```bash
kubectl -n ingress-nginx get pods -o wide   # 应只在 k8swork1/k8swork2 起
kubectl -n ingress-nginx get svc            # Service type=ClusterIP
```

### 4.7 步骤 6:ingress 开 proxy-protocol(收 HAProxy 的真实 IP)

```bash
kubectl -n ingress-nginx edit cm ingress-nginx-controller
```

在 `data:` 下加:

```yaml
data:
  use-proxy-protocol: "true"
  use-forwarded-headers: "true"
  compute-full-forwarded-for: "true"
```

```bash
kubectl -n ingress-nginx rollout restart ds/ingress-nginx-controller
```

**坑②(致命)**:开了 `use-proxy-protocol: "true"` 后,**任何不带 proxy-protocol 头的连接都会握手失败**。这意味着:
- 现有"直接 curl 节点 IP" 的健康检查、监控、内部访问 **全部会断**。
- **必须通过 HAProxy(`<NEW_PUBLIC_IP>`)访问 ingress**;直连 `192.168.100.11:80` 不再可用。
- 排查 ingress 时改用 `kubectl logs` / `kubectl exec`,不要直 curl 节点端口。

### 4.8 步骤 7:端到端验证

```bash
# 1) 一个最小测试 Ingress(命名空间随你)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata: { name: lb-test }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: echo, namespace: lb-test }
spec:
  replicas: 2
  selector: { matchLabels: { app: echo } }
  template:
    metadata: { labels: { app: echo } }
    spec:
      containers:
      - name: echo
        image: hashicorp/http-echo:latest
        args: ["-text=hello from $(POD_NAME)"]
        env:
        - name: POD_NAME
          valueFrom: { fieldRef: { fieldPath: metadata.name } }
        ports: [{ containerPort: 5678 }]
---
apiVersion: v1
kind: Service
metadata: { name: echo, namespace: lb-test }
spec:
  selector: { app: echo }
  ports: [{ port: 80, targetPort: 5678 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo
  namespace: lb-test
spec:
  ingressClassName: nginx
  rules:
  - host: test-ingress.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: { service: { name: echo, port: { number: 80 } } }
EOF

# 2) DNS 还没切 → 直接打公网 IP + Host 头(模拟生产解析)
curl -H 'Host: test-ingress.example.com' http://<NEW_PUBLIC_IP>/
# 期望:看到 "hello from echo-xxxxx"

# 3) 多打几次,看是否轮询到两个 pod(leastconn 不严格轮询,大致均衡即可)
for i in $(seq 1 10); do curl -s -H 'Host: test-ingress.example.com' http://<NEW_PUBLIC_IP>/; done

# 4) 查 HAProxy 后端状态
echo "show stat" | socat stdio /run/haproxy/admin.sock | column -ts,
#   或浏览器内网访问 http://192.168.100.41:9000/

# 5) 真实客户端 IP 透传验证(在外网某机器上)
curl -H 'Host: test-ingress.example.com' http://<NEW_PUBLIC_IP>/
kubectl -n ingress-nginx logs ds/ingress-nginx-controller --tail=20 | grep -i 'remote'
# 期望 access log 里 client IP 是外网真实 IP,不是 192.168.100.41

# 6) 反向验证:确认现有业务零影响
#    - 现有公网 IP 116.211.238.197 业务功能正常
#    - K8s 节点出站正常:在节点上 curl ifconfig.me,出口 IP 应仍是 116.211.238.197(不是 NEW)
#    - 其他业务监控指标无波动
```

---

## 5. DNS 切流(全量上线)

**灰度顺序**(按风险从低到高):

```
1. 测试子域 test-ingress.example.com  → <NEW_PUBLIC_IP>     ← 第 4.8 已验证
2. 一个低流量业务域名                  → <NEW_PUBLIC_IP>     ← 跑 1–3 天
3. 主域名(TTL 提前调到 60s)           → <NEW_PUBLIC_IP>     ← 全量切
4. 观察 1–2 周稳定后,把现网 nginx 上的 ingress 反代规则撤掉(如果它原来也做了)
```

**回滚**(任何一步出问题):DNS A 记录改回 `116.211.238.197`,客户端 TTL 内自动回退,集群/HAProxy 不用动。

---

## 6. 坑 & 注意点(分类清单)

### 6.1 网络配置类

| # | 坑 | 防御措施 |
|---|---|---|
| ⚠️ 1 | 双网卡配两个 GATEWAY → 路由混乱 | 只在 eth0 配默认网关,eth1 只配 IP |
| ⚠️ 2 | HAProxy 盒子开了 `ip_forward` → 意外当网关 | **保持 `ip_forward=0`**,本方案纯代理不转发 |
| ⚠️ 3 | `bind *:80` 而非 `bind <NEW_PUBLIC_IP>:80` → 把内网 9000 状态页暴露 | 显式绑公网 IP |
| ⚠️ 4 | stats 页绑 `0.0.0.0:9000` 且无密码 → 公网可访问 | 绑 `192.168.100.41:9000` + `stats auth` 强密码 |
| ⚠️ 5 | 防火墙规则没放行内网 :9000(管理用) | iptables/security group 放行运维 IP 段 |
| ⚠️ 6 | 公网 IP 路由黑洞 — 机房交给你之前没配下一跳 | 上线前 `ping` 自身公网 IP 网关 + 外网测试 |

### 6.2 HAProxy & ingress 配合类

| # | 坑 | 防御措施 |
|---|---|---|
| ⚠️ 7 | **开 `use-proxy-protocol` 后直 curl 节点失败** | 监控/健康检查改打 HAProxy VIP,**不要**直连节点 |
| ⚠️ 8 | `send-proxy-v2` 后端期望 v2,只发 v1 → 后端拒收 | 两边版本对齐:HAProxy `send-proxy-v2`,ingress 默认收 v2 |
| ⚠️ 9 | TLS 边缘终止 vs 节点终止混淆 → 证书裂脑 | 本方案是 **节点终止**(`mode tcp` 透传),证书放 K8s Secret 即可 |
| ⚠️ 10 | ingress Service 不小心配成 LoadBalancer → EXTERNAL-IP pending,监控误报 | 显式 `--service-type=ClusterIP` |
| ⚠️ 11 | 后端 leastconn 倾斜 — 单 pod 异常时所有连接全压上去 | 加 `option httpchk` + `maxconn` per server,异常自动剔除 |
| ⚠️ 12 | HAProxy `daemon` 模式 + systemd 时双重 PID | 用 systemd unit 自带,不要加 `daemon` 也可;包默认 unit 已处理,保留 `daemon` 也 ok |

### 6.3 性能 & 容量类

| # | 坑 | 防御措施 |
|---|---|---|
| ⚠️ 13 | active 单台扛全量,带宽/PPS 单机上限 | 容量规划:确认 HAProxy 盒子网卡 + CPU 能撑业务峰值,留 50% headroom |
| ⚠️ 14 | `ip_local_port_range` 默认窄 → 出连接到 ingress 节点端口耗尽 | 已在 §4.2 sysctl 里改成 10000-65000 |
| ⚠️ 15 | `nf_conntrack` 表小 → 高并发丢连接 | `sysctl net.netfilter.nf_conntrack_max=1048576` |
| ⚠️ 16 | HAProxy `maxconn` 200000 但 nofile 没改 → EMFILE | 已在 §4.2 limits.conf 改 |

### 6.4 安全 & 运维类

| # | 坑 | 防御措施 |
|---|---|---|
| ⚠️ 17 | 新公网 IP 无任何防护 — 直接被扫端口 / DDoS | 上 cloud firewall / iptables 限 80/443 入站,其余 drop |
| ⚠️ 18 | 没监控 HAProxy 进程存活、后端状态 | Prometheus haproxy_exporter + alert;或 stats 页脚本采集 |
| ⚠️ 19 | 没日志归档 — 出事查不到 | `/var/log/haproxy.log` 接 rsyslog → 中心化日志 |
| ⚠️ 20 | 没演练切回原 nginx — 真出事不会回滚 | 上线前演练一次:把 DNS 切到 `116.211.238.197`,观察自动回退 |

### 6.5 现有 ingress-nginx 已部署的情况

如果 ingress-nginx **已经装好且业务在用**,要小心:
- `use-proxy-protocol` 是**全局**的,一旦开启,**所有**进入 ingress 的流量都必须带 proxy-protocol 头。
- 现有走"节点 IP:80 直访"的客户端(监控、内部调用)会**立刻断**。
- **处理顺序**:① 先调研所有调 ingress 的源,把直访改成走 HAProxy;② 再打开 `use-proxy-protocol`;③ 否则保持关闭,但损失真实客户端 IP。
- **替代方案**:不开 proxy-protocol,改用 HAProxy `mode http` + 注入 `X-Forwarded-For` 头 —— 但 TLS 就要在边缘终止,证书要搬出来,改动反而大。**建议第一种**,把内部直访收编。

---

## 7. 第二阶段:升 HA(双机 Keepalived)

单机跑稳后(建议 ≥ 1 周)再升 HA。前提:**机房允许 `<NEW_PUBLIC_IP>` 的 ARP/MAC 在两台之间漂移**(VRRP 必需,见 lb-comparison.md §3.1)。

### 7.1 加一台 HAProxy 盒子(nginx-new2, 内网 192.168.100.42)

- 系统初始化 §4.2、装 HAProxy §4.4、HAProxy 配置 §4.5 **完全一样**(同一份 cfg)。
- eth0 网卡**不配**公网 IP(平时无 IP,由 keepalived 动态挂)。
- 验证两台 HAProxy 单独跑都能反代成功(临时把公网 IP 手工挪到第二台测一下)。

### 7.2 启 Keepalived(只新增 VRRP,HAProxy 配置不变)

`/etc/keepalived/keepalived.conf`(MASTER = nginx-new1):

```conf
global_defs {
    router_id nginx-new1
    enable_script_security
    script_user root
}

vrrp_script chk_haproxy {
    script "/usr/bin/killall -0 haproxy"
    interval 2
    weight -40
    fall 2
    rise 2
}

vrrp_instance VI_INGRESS {
    state MASTER
    interface eth1                      # 心跳走内网网卡
    virtual_router_id 71                # 同网段唯一,别和现网 VRRP 撞
    priority 100
    advert_int 1
    unicast_src_ip 192.168.100.41
    unicast_peer { 192.168.100.42 }
    authentication { auth_type PASS; auth_pass <CHANGE_ME> }
    virtual_ipaddress {
        <NEW_PUBLIC_IP>/<掩码> dev eth0
    }
    track_script { chk_haproxy }
}
```

BACKUP(nginx-new2)只改:`router_id nginx-new2` / `state BACKUP` / `priority 90` / `unicast_src_ip 192.168.100.42` / `unicast_peer { 192.168.100.41 }`。

启动:`systemctl enable --now keepalived`(两台都启)。

**重点变更**:HAProxy 配置里 `bind <NEW_PUBLIC_IP>:80/443` 现在绑的是 VIP —— 之前 §4.2 已经开了 `net.ipv4.ip_nonlocal_bind=1`,backup 上即使没 VIP 也能正常加载配置等待接管。

### 7.3 升 HA 时的注意

| # | 坑 |
|---|---|
| ⚠️ 21 | `virtual_router_id` 和现网/其他 VRRP 撞 → 选举冲突 | 用 71 这种现网没用过的值 |
| ⚠️ 22 | 切换瞬间 TCP 连接重置(默认行为) | 接受;长连接重要业务上 `conntrackd` 同步(非必须) |
| ⚠️ 23 | 机房锁 MAC → VIP 漂不过去 | 上 HA 前再次跟机房确认,`arping -U` 自验 |
| ⚠️ 24 | nginx-new2 eth0 不能配公网 IP — 否则 keepalived 加 VIP 冲突 | eth0 平时无 IP,VRRP 动态挂 |

---

## 8. "现业务零影响" 验收清单(上线前 + 上线后各跑一遍)

| 验收项 | 命令 / 现象 | 上线前 | 上线后 |
|---|---|---|---|
| 现有公网 IP `116.211.238.197` 可达 | 外网 `curl https://116.211.238.197/` | ✅ | ✅ 必须一致 |
| K8s 节点出站公网 IP 未变 | 节点 `curl ifconfig.me` | =原值 | =原值,必须一致 |
| 节点 `ip route` 默认网关未变 | `ip route show default` | 记录 | 必须一致 |
| 现网 nginx 进程/端口未变 | 现网 nginx `ss -lntp` | 记录 | 必须一致 |
| 其他业务监控(QPS / 错误率 / 时延) | Prometheus / Grafana | 记录基线 | 不超基线 ±5% |
| K8s 节点 → 外部依赖(DB / 第三方 API) | 业务侧日志 | 正常 | 正常 |
| pod 到 pod 流量 | `kubectl exec` 互 ping/curl | 正常 | 正常 |
| 现网 nginx → 后端可达 | 现网 nginx 的健康检查日志 | 正常 | 正常 |

> 任何一项异常 → 不切流,排查根因。本方案设计上**没有任何路径会影响以上指标**,出现异常说明有遗漏配置(典型:不小心开了 ip_forward / 改了节点路由)。

---

## 9. 验证清单 / 故障速查

### 9.1 日常验证

```bash
# HAProxy 进程 + 监听
systemctl status haproxy
ss -lntp | grep -E '<NEW_PUBLIC_IP>:(80|443)'

# 后端状态
echo "show stat" | socat stdio /run/haproxy/admin.sock | awk -F, '{print $1,$2,$18}'

# 端到端
curl -I -H 'Host: <你的域名>' http://<NEW_PUBLIC_IP>/

# 真实 IP 透传
kubectl -n ingress-nginx logs ds/ingress-nginx-controller --tail=50 | grep -oE 'client: [0-9.]+'

# (升 HA 后)VIP 当前在哪台
ip addr show eth0 | grep <NEW_PUBLIC_IP>
```

### 9.2 常见故障

| 现象 | 排查方向 |
|---|---|
| `curl <NEW_PUBLIC_IP>` 超时 | ① 公网 IP 路由不通 → 机房 ② iptables 拦了 ③ HAProxy 没起 ④ bind 错误 IP |
| HAProxy `show stat` 后端 DOWN | ① 节点 :443 不通(防火墙)② ingress pod 没起 ③ proxy-protocol 还没开 ConfigMap → ssl-hello-chk 失败 |
| 后端日志看到 `192.168.100.41` 不是真实 IP | `use-proxy-protocol` 没开 / 没 reload ingress |
| 切换 HA 后业务断 | ① 机房锁 MAC ② keepalived `virtual_router_id` 冲突 ③ `unicast_peer` 配反 |
| 现有业务受影响 | 立刻 `cat /proc/sys/net/ipv4/ip_forward` 看是不是误开了;`ip route` 看默认路由是否被改 |

---

## 10. 一页纸总结(给上面看的)

**做什么**:申请 1 个新公网 IP,新增 1 台 HAProxy 盒子做旁挂入站反代,先单机后双机。

**为什么不影响现业务**:HAProxy 是全代理,回包走 L2 直达,不经任何网关 → 现有公网 IP/网关/出口/其他业务**零改动**。

**差什么**:1 个新公网 IP + 1(后期 2)台 HAProxy 盒子(双网卡)+ 几个内网 IP。

**关键坑**:① 节点默认网关不能动;② HAProxy 不开 ip_forward;③ stats 不要绑 0.0.0.0;④ 开 use-proxy-protocol 后内部直访节点会断,先收编;⑤ 升 HA 前确认机房允许 ARP 漂移。

**回滚**:DNS 切回 `116.211.238.197`,集群/HAProxy 不用动。
