# HAProxy + ingress-nginx + dsp 链路压测诊断笔记

> 一次"QPS 上不去"的排查,从怀疑 HAProxy 一路追到压测机网卡。
> 留个底,下次再有人问同样问题直接看这里。

---

## TL;DR

**单机 ai02 走 HAProxy 跑 dsp 静态前端,QPS 天花板就是 ~69K**,瓶颈 100% 是**压测机千兆网卡**,不是 HAProxy / ingress / k8s / 应用层。要再往上只能 (1) 多机分布式压测,(2) 升 10G 网卡。

排查中走过的弯路按时间顺序:
1. 怀疑 HAProxy 不均衡 → ❌(nbthread 12,maxconn 100K,CPU 才 8%)
2. 怀疑 HTTP/2 多路复用 → ❌(加 `-http1` 无显著变化)
3. 怀疑后端 pod 算力不足 → ❌(`kubectl top` 显示都没忙)
4. 怀疑 dsp-admin 副本数(1/2) → ❌(扩到 6 反而 QPS 下降)
5. 怀疑 nginx 反代到 Java 服务 → ❌(看 nginx.conf 是纯静态 SPA,没 proxy_pass)
6. **真相 A:压测机千兆网卡 100% 满**(`ifstat` 937 Mbps)✓
7. **真相 B:wrk 默认不送 `Accept-Encoding`,gzip 没启用** ✓

加 gzip 头后 QPS 立刻从 35K 跳到 69K,与响应体 2800B → 1154B 的压缩比一致。

---

## 链路拓扑

```
[wrk on ai02 (192.168.150.117)]
     │  1Gbps eno1   ← 真瓶颈
     ▼
[HAProxy on ai02]               # 同机部署,localhost loopback
     │  nbthread=12, maxconn=100K, 8% CPU 闲到发慌
     ▼
[ingress-nginx × 2]             # 7m CPU,完全空闲
   192.168.150.242 / 243
     │
     ▼
[Service dsp-admin (ClusterIP)]
     │  iptables / ipvs
     ▼
[dsp-admin pod × 2]             # 纯静态 nginx serve SPA dist
   container nginx 8080, /usr/share/nginx/html
```

**关键事实**:dsp-admin 是 vite 打出来的前端 SPA dist,nginx 只 serve 静态文件,**没有 proxy_pass 到 Java 后端**。所以扩 dsp-admin 副本对 QPS 几乎没帮助。

---

## 各阶段压测数据

工具:`wrk -t N -c C -d 30s --latency`

| 阶段 | 场景 | 并发 | QPS | p50 | p99 | Transfer | 说明 |
|---|---|---|---|---|---|---|---|
| Go 自研 | 走 HAProxy | c=200 | 30445 | 4.7ms | 19ms | - | 客户端先饱和,链路没压满 |
| Go 自研 | 同时压 242+243 c=400 | c=400 | 38003 | 6.93ms | 44ms | - | 客户端封顶 |
| wrk | 走 HAProxy | c=400 | 34088 | 6.3ms | **360ms** | 102 MB/s | 网卡满,延迟爆 |
| wrk | 直压 242 | c=400 | 30250 | 12.6ms | 179ms | 91 MB/s | ~720 Mbps |
| wrk | 直压 243 | c=400 | 28910 | 10.7ms | 220ms | 87 MB/s | 两台对称 |
| wrk × 2 机 | 双机直压 | 共 c=400 | 41122 | - | - | 124 MB/s | 网卡分散 |
| wrk × 2 机 | 双机直压 + dsp-admin 扩 6 副本 | 共 c=400 | **36854 ↓** | - | - | - | 扩副本反而降 |
| **wrk + gzip** | **走 HAProxy** | **c=200** | **69365** | **2.71ms** | **210ms** | **101 MB/s** | **最终上限** |
| wrk + gzip | 直压 242 | c=200 | 52617 | 3.32ms | 190ms | 77 MB/s | HAProxy 分流 +33% |

**响应体大小**(curl 实测):
- 无 `Accept-Encoding`: 2800 B
- 带 `Accept-Encoding: gzip`: 1154 B(压缩比 41%)

---

## 诊断三板斧(下次排查时按顺序看)

### 1. 看压测机网卡有没有满

```bash
ifstat 1
# 或
sar -n DEV 1 10 | grep -E "Average|eno|ens|enp"
# 看网卡速率
cat /sys/class/net/*/speed
```
入向 / 出向任何一个接近 `网卡 speed` 的 95%,就是它。**ai02 的千兆 = 实际 ~940 Mbps**。

### 2. 看 HAProxy 是不是真忙

```bash
# HAProxy 进程 CPU(注意 nbthread 12 时 %CPU 可超 100)
top -p $(pgrep -d, haproxy)

# stats 页(配置里已开 8404)
curl -s "http://127.0.0.1:8404/stats?stats;csv" | awk -F, '$2~/FRONTEND|BACKEND/'
```
如果 CPU < 20%、`scur` 远低于 `slim`,**HAProxy 没事**,瓶颈在前后两侧。

### 3. 看 ingress + 业务 pod CPU

```bash
# 压测同时另开终端
watch -n 1 'kubectl top pod -n dsp-test --sort-by=cpu; echo ---; kubectl top pod -n ingress-nginx'
```
- 业务 pod CPU 飙到 limit → 算力瓶颈,扩副本 / 升 limits
- 业务 pod CPU 低但延迟陡崖 → 应用层(线程池 / 下游服务 / DB)
- 全员悠闲 → 看网卡

---

## 内核调优参考清单(⚠ 不要无脑全量套用)

**install.sh 不自动改内核**。下面这些参数在某些场景能提升 HAProxy 吞吐,
但有副作用 / 兼容性风险,生产环境请按需逐项评估、灰度后再用:

| 类别 | key | 参考值 | 风险 |
|---|---|---|---|
| 连接队列 | `net.core.somaxconn` | 65535 | 通常安全 |
| | `net.ipv4.tcp_max_syn_backlog` | 16384 | 通常安全 |
| | `net.core.netdev_max_backlog` | 10000 | 通常安全 |
| TIME-WAIT | `net.ipv4.tcp_tw_reuse` | 1 | **NAT 环境下可能丢包**,Linux 4.12+ 默认行为有变 |
| | `net.ipv4.tcp_fin_timeout` | 15 | 缩短可能让短命连接更快 reset |
| 端口范围 | `net.ipv4.ip_local_port_range` | 1024-65535 | 与 ephemeral port 用法冲突时需排查 |
| socket buffer | `net.core.{r,w}mem_max` | 16 MB | **吃内存**,小内存机器谨慎 |
| 文件描述符 | `fs.file-max` / `fs.nr_open` | 2097152 | 改太高某些容器/cgroup 不接受 |
| conntrack | `nf_conntrack_max` | 1048576 | 模块未加载时 sysctl 报错;部署链路涉及 NAT/iptables 才需要 |
| 拥塞控制 | `tcp_congestion_control` | bbr | **bbr 在某些内核/网卡组合下表现反而不如 cubic**,要 A/B 测 |
| | `net.core.default_qdisc` | fq | 与 bbr 配套 |
| 其它 | `tcp_fastopen` | 3 | TFO 与部分中间设备 / 防火墙不兼容 |
| | `tcp_slow_start_after_idle` | 0 | 长连接复用受益,短连接无差异 |

systemd 侧:`/etc/systemd/system/haproxy.service.d/limits.conf`
```ini
[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
```
这一项**比较安全**(默认 1024 fd 高 QPS 下肯定不够),手动加即可。

**实测结论**:本次诊断中,**这套参数没有调,QPS 已经撞到了千兆网卡的物理上限**。
也就是说,内核调优不是当前瓶颈所在,先不动它没问题。
要调时,**一次只改一项,压测对比,有副作用立刻回滚**。

---

## 复现压测命令(留作模板)

### 单机走 HAProxy(典型快速测试)
```bash
wrk -t 4 -c 200 -d 30s --latency \
  -H "Accept-Encoding: gzip" \
  https://test-dsp.wishfoxs.com/
```

### 直压单台 ingress(排除 HAProxy 嫌疑)
```bash
wrk -t 4 -c 200 -d 30s --latency \
  -H "Accept-Encoding: gzip" \
  -H "Host: test-dsp.wishfoxs.com" \
  https://192.168.150.242/
```

### 双机同步起跑(突破单机网卡的关键)
两边各自:
```bash
T=$(($(date +%s) + 10 - $(date +%s) % 10))
while [ $(date +%s) -lt $T ]; do sleep 0.1; done
wrk -t 4 -c 200 -d 30s --latency \
  -H "Accept-Encoding: gzip" \
  https://test-dsp.wishfoxs.com/
```
两边都会等到下一个整 10 秒起跑,真正同步。

### 同时盯 K8s 侧 CPU
```bash
watch -n 1 'kubectl top pod -n dsp-test --sort-by=cpu | head -10; echo ---; kubectl top pod -n ingress-nginx'
```

---

## 想继续提升 QPS 的优先级

| 动作 | 收益 | 难度 |
|---|---|---|
| **客户端必带 `Accept-Encoding: gzip`** | QPS ×2(35K → 69K) | 一行 header |
| HAProxy 加 `http-reuse always`(已在 install.sh) | 后端连接复用,长压更稳 | 配置 |
| 多机分布式压测(2 台合压) | 单机 69K → 双机 130K+ | 拉一台机器 |
| ai02 网卡换 10G | 单机直接 200K+ | 硬件 |
| 给 dsp-admin / ingress-nginx 加 HPA | 抗流量峰值 | k8s 配置 |
| 应用响应体瘦身(去掉冗余字段) | 等比例提升 QPS | 应用改 |

不要做的事(已验证无收益):
- 扩 dsp-admin 副本(从 2 扩到 6 反而抖动下降)
- 调 Tomcat / Java 参数(dsp-admin 是 nginx 静态,不是 Java)
- 折腾 HTTP/1.1 vs HTTP/2 切换(几个百分点差异,与瓶颈无关)
- 调 HAProxy nbthread(已经是 12,CPU 才 8%)

---

## 重要 takeaway

1. **压测前先看响应大小**。1KB 跟 10KB 的差距是 QPS 上限的差距,跟服务端没关系。
2. **wrk 默认不发 `Accept-Encoding`**,如果你的服务靠 gzip 压缩省带宽,压测数据会严重失真(失真程度 = 压缩比)。
3. **千兆网卡的物理极限是 ~120 MB/s**,如果你的服务端能产生这个流量,瓶颈就是网卡,跟应用毫无关系。
4. **CPU 没满不等于没瓶颈** —— 还可能是线程池 / 连接池 / 网卡 / 内核 backlog / socket buffer。
5. **扩副本不一定提 QPS**,如果真瓶颈在客户端、网络、或下游单点,扩副本反而引入更多抖动。
6. **ai02 既是压测机又是 HAProxy 主机**这种部署会让网卡瓶颈更早出现(同一张网卡承担入流量 + loopback 流量),诊断时要把"压测客户端"和"被测服务"分开,否则数据无法解读。

---

## 后期升级路径:加 Keepalived 做 HA(P2,暂未实施)

> 当前:单台 HAProxy 已能稳定承载 ~69K QPS,功能够用。
> 未来当单机故障风险无法接受、或带宽不够要双活时,按下面步骤扩展。

### 方向选定:单公网 IP + Keepalived 主备

机房环境(物理 IDC,非云 EIP)。对比过单 IP 主备 / 多 IP 双活 / DNS 轮询,
**单 IP + Keepalived 主备** 综合最优:

- 故障切换 1-3 秒,客户端 TCP 重连即可,无感
- 不依赖 DNS TTL(多 IP 方案最大的雷)
- 第三方白名单一个 IP 搞定
- 代价:备机平时空闲,资源利用率 50%(可接受)

### 前置硬要求

**机房接入交换机必须允许 VRRP / gratuitous ARP / 多 MAC 绑同 IP**。

落地前先开工单问机房:
> 我们想在两台服务器之间用 VRRP 协议漂移一个公网 IP 做高可用,
> 接入交换机是否允许 gratuitous ARP / 多 MAC 绑定同一 IP?

机房不支持的话本方案直接作废,得退回多 IP + DNS 轮询(那是另一套故事)。

### 实施阶段(顺序不能跳)

工程上**绝对不能 HAProxy 和 keepalived 同时部署**,会让故障定位无法分层。
正确的顺序是 HAProxy 单台稳 → 双台都稳 → 再叠 keepalived:

**阶段 1:第一台 HAProxy 单机跑稳**(当前状态 ✓)
- 已通过 `install.sh` 部署,实测 ~69K QPS,链路正常
- 监控、日志、告警接入完成

**阶段 2:加第二台 HAProxy,独立运行验证一致性**
- 新机用同一份 `install.sh` 装,后端 ingress 列表相同
- 用临时 IP 单独压测,确认与第一台 QPS / 延迟对齐(<5% 偏差)
- 配置文件 diff 一遍,只允许 stats password 这种本机相关字段不同
- 这一阶段两台 HAProxy 并行运行,但**没有 VIP**,各自直接对外服务
- 跑 1-3 天观察,确认稳定

**阶段 3:加 Keepalived 拉 VIP**
- 阶段 2 没问题再做,否则等于在病人身上做手术
- 走 `install-keepalived.sh`(还没写)+ `keepalived.conf.tpl`
- 先用低 priority 在 BACKUP 装,确认不抢主,再装 MASTER
- 验证 VIP 漂移:手动 `systemctl stop haproxy` 看是否 1-3 秒内切到 BACKUP
- 验证回切:再启动主 HAProxy,确认 `nopreempt` 生效(VIP 不抢回)

每个阶段进入下一阶段前,都要确认"如果回退,代价可控"。比如阶段 3 出问题,
应该能在 5 分钟内通过 `systemctl stop keepalived` 让 VIP 落回某一台,流量不断。

### 实施时需要的信息(写脚本前要收集)

| 项 | 说明 |
|---|---|
| 两台 HAProxy 内网 IP | VRRP 单播通信用,不走公网 |
| 漂移的公网 VIP + 掩码 | 机房分配,允许多 MAC 绑定 |
| 各自的 VIP 网卡名 | 两台可能不同(eno1 vs ens33) |
| VRID(virtual_router_id) | 机房全网段唯一,50+ 随便取 |
| HAProxy 健康检查方式 | 建议 `curl -fs 127.0.0.1:8404/healthz` |

### 脚本规划

跟现有 `install.sh` 平级,文件清单:

| 文件 | 状态 | 作用 |
|---|---|---|
| `check_haproxy.sh` | ✓ 已写 | Keepalived `track_script` 用的健康检查,独立组件,先放着等被引用 |
| `install-keepalived.sh` | ✗ 待写 | 安装 keepalived + 写 sysctl + cp check_haproxy.sh + 生成配置 |
| `keepalived.conf.tpl` | ✗ 待写 | VRRP 配置模板,占位符 `__VIP__` / `__VRID__` / `__PRIORITY__` 等 |

两台机器各跑一次 install-keepalived.sh:

```bash
# 主机 A
bash install-keepalived.sh --role=master --priority=100 \
  --vip=<公网 IP>/29 --vip-iface=eno1 \
  --peer=192.168.150.118 --vrid=51

# 主机 B
bash install-keepalived.sh --role=backup --priority=90 \
  --vip=<公网 IP>/29 --vip-iface=ens33 \
  --peer=192.168.150.117 --vrid=51
```

### 关键配置点(写脚本/模板时不能漏)

1. **`net.ipv4.ip_nonlocal_bind = 1`** — HAProxy 才能 bind 还没漂过来的 VIP,这条 sysctl 是 HA 必需的,本身安全
2. **`state` 都用 `BACKUP` + `priority` 分高低 + `nopreempt`** — 防止主恢复后 VIP 反复漂移
3. **`unicast_peer { <对端 IP> }`** — IDC 基本都禁组播 224.0.0.18,必须用单播
4. **`virtual_router_id`** — 机房全网段唯一,撞了会跟别人的 VRRP 串
5. **`track_script` 检测 HAProxy listener,不要只 `pgrep`** — 进程在但端口挂掉的情况要能感知,推荐 `curl -fs 127.0.0.1:8404/`
6. **`notify_master` / `notify_backup` 写日志到 syslog** — 切换历史可追溯
7. **split-brain 防御** — 两台都收不到 VRRP 包时双方都成 MASTER → VIP 冲突。短期靠监控发现,长期可加 quorum 检测(双方都 ping 同一个网关)

### 省钱小招

备机不用跟主机同配置。主机满配抗常态流量,备机半配只跑 keepalived,
切换后扛短期峰值,等主机修复再切回。机房账单能省 30-50%。

---

*生成日期:2026-06-18*
