# TCP 连接状态速查 — ss 一行统计 + 解读

> 状态: ✅ 生产现场使用

服务器(尤其 GitLab / 反代 / API gateway)上"连接数飙了 / fd 不够 / 端口耗尽"时,**第一步**先跑这条:

```bash
ss -tan | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn
```

## 这条命令在做什么

| 段 | 作用 |
|---|---|
| `ss -tan` | `-t` TCP / `-a` 全部(含 LISTEN)/ `-n` 不解析 DNS 端口名(快) |
| `awk 'NR>1 {print $1}'` | 跳第 1 行表头,取第 1 列(`State`) |
| `sort \| uniq -c` | 排序后按状态去重计数 |
| `sort -rn` | 按数量倒序 |

## 真实样本(GitLab 服务器)

```
$ ss -tan | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn
   1971 ESTAB
     51 CLOSE-WAIT
     42 LISTEN
     18 TIME-WAIT
```

## 解读对照表

| 状态 | 含义 | 这个样本算什么 | 经验阈值 |
|---|---|---|---|
| `ESTAB`(ESTABLISHED) | 正常活跃连接 | **1971** — GitLab 多客户端 git pull/push + Web,**正常水位** | 不设硬上限,关注趋势 |
| `LISTEN` | 在监听的服务端口 | **42** — Nginx + GitLab Workhorse + Puma + Sidekiq + Gitaly + Prometheus 等,合理 | 跟实际服务数对得上即可 |
| `TIME-WAIT` | 主动关闭方等 2MSL 回收 | **18** — 极少,**连接复用做得好** | 健康;>10000 才要调 `net.ipv4.tcp_tw_reuse` |
| **`CLOSE-WAIT`** | **对端关了,本端 app 没 close()** | **51** — ⚠ 偏多,**可能 fd 泄漏苗头**,要追 | **任何时候 >20 就该查**;持续涨就是 bug |
| `FIN-WAIT-1/2` | 本端发了 FIN,等对端 | 没出现 = 健康 | 持续增长 = 对端不回 ACK / 中间设备丢包 |
| `LAST-ACK` | 收对端 FIN 后等最后 ACK | 没出现 | 偶发正常 |
| `SYN-SENT` / `SYN-RECV` | 三次握手中间态 | 没出现 | 持续 SYN-RECV 增长 = SYN flood |

> 这个样本里 **CLOSE-WAIT=51 是唯一需要追查的点**。其他都健康。

## CLOSE-WAIT 偏多怎么追

```bash
# 1. 看 CLOSE-WAIT 都连到哪些对端
ss -tan state close-wait | awk 'NR>1 {print $5}' | sort | uniq -c | sort -rn

# 2. 看 CLOSE-WAIT 是哪些本地端口(=哪个服务)
ss -tanp state close-wait | awk 'NR>1 {print $4}' | sort | uniq -c | sort -rn

# 3. 直接定位进程
ss -tanp state close-wait
# users:(("ruby",pid=12345,fd=42))
# 或
sudo lsof -nP -iTCP -sTCP:CLOSE_WAIT

# 4. 看进程 fd 泄漏趋势
ls /proc/<pid>/fd | wc -l            # 多采几次看是不是单调涨
cat /proc/<pid>/limits | grep -i open  # 上限
```

CLOSE-WAIT 是**应用层 bug**(打开了 socket 没 close),内核帮不了你。常见元凶:

- HTTP client 没 `defer resp.Body.Close()`
- Redis / DB 连接池配置错,池子里连接死了不回收
- 反代上游断连后没释放(老版本 nginx + keepalive 偶现)
- Ruby/Puma worker 异常退出但 fd 没全清

## 配套排查命令(同一类问题往这儿堆)

### 按对端 IP 看 ESTAB 分布(谁连得最多)

```bash
ss -tan state established | awk 'NR>1 {split($5,a,":"); print a[1]}' | sort | uniq -c | sort -rn | head -20
```

### 按本地端口看连接分布(哪个服务最忙)

```bash
ss -tan state established | awk 'NR>1 {split($4,a,":"); print a[length(a)]}' | sort | uniq -c | sort -rn | head
```

### 当前 fd 总数 vs 上限(内核层)

```bash
cat /proc/sys/fs/file-nr
# 输出: <已分配> <已分配未用> <上限>
# 上限改: sysctl -w fs.file-max=2097152
```

### 单进程 fd

```bash
# 排前 10 个 fd 大户
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  cnt=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
  [ "$cnt" -gt 100 ] && echo "$cnt $(cat /proc/$pid/comm 2>/dev/null) $pid"
done | sort -rn | head
```

### TIME-WAIT 飙高(对端短连接风暴)

```bash
ss -tan state time-wait | wc -l

# 看是谁刷
ss -tan state time-wait | awk 'NR>1 {split($5,a,":"); print a[1]}' | sort | uniq -c | sort -rn | head

# 临时缓解(仅 client 侧有效,不要无脑开 tcp_tw_recycle 内网 NAT 后翻车)
sysctl -w net.ipv4.tcp_tw_reuse=1
```

### conntrack 满(NAT 网关 / 防火墙节点)

```bash
# 数表 vs 上限
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

# 满了就 dmesg 一片 "nf_conntrack: table full, dropping packet"
dmesg -T | grep -i conntrack | tail
```

### 端口耗尽(本地发起连接的 ephemeral 池)

```bash
# 当前 ephemeral 范围
cat /proc/sys/net/ipv4/ip_local_port_range
# 默认 32768-60999 ≈ 28k,扛不住短连接

# 看是哪个本地 IP : 哪个对端端口最热
ss -tan state established | awk 'NR>1 {print $4 " -> " $5}' | sort | uniq -c | sort -rn | head
```

## 一些经验判断

| 现象 | 意味着 |
|---|---|
| `ESTAB` 持续涨,`CLOSE-WAIT` 也涨 | **应用 fd 泄漏**,迟早 OOM / accept 失败 |
| `ESTAB` 正常,`CLOSE-WAIT` 涨 | 同上,但还没到爆点 |
| `TIME-WAIT` 几万 | 主动关闭方是这台,短连接多,**正常但浪费端口**,看是否要 keepalive |
| `SYN-RECV` 几百+ | **SYN flood / 半连接队列满**,看 `net.ipv4.tcp_max_syn_backlog` 和 `somaxconn` |
| `FIN-WAIT-2` 涨 | 对端不发 FIN-ACK(中间防火墙 / NAT 超时清表) |
| `LAST-ACK` 多 | 跟 FIN-WAIT-2 对称,本端在等对端最后 ACK |

## 相关

- 应用层 fd 泄漏:`ls /proc/<pid>/fd` 单调涨 → 上 `strace -p <pid> -e close,accept` 或代码层 grep `Body.Close`
- 连接数压测瓶颈案例:[../haproxy/PERF-DEBUG.md](../haproxy/PERF-DEBUG.md)(单机网卡 / wrk 配置如何影响 QPS 天花板)
