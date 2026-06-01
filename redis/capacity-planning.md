# Redis 容量规划 / 性能瓶颈速查

> Redis 跟 MySQL 完全不是一个故事 — **单线程 + 全内存**,核心瓶颈不是 CPU/IO,而是**内存大小 + 单核 QPS + 网络 RTT**。
> 排障时直接复制粘贴下面的命令清单。

## 完整请求链路

```
业务进程 (Java/Go/Python)
  ↓ ① 应用连接池 (Jedis / lettuce / go-redis)
  ↓ TCP/6379  ── 这里 RTT 是个隐形大头
Redis Cluster Proxy (twemproxy / predixy / redis-cluster-proxy, 可选)
  ↓ TCP/6379  ── 路由到 slot 对应的 master
Redis Server 进程
  ├─ ② 主线程(单线程)
  │     ├─ accept 连接(epoll)
  │     ├─ 解析协议 (RESP)
  │     ├─ 执行命令         ← 全部在这一根线程上!
  │     └─ 回写客户端
  ├─ ③ IO Threads(6.0+ 可选, 默认关) 只做网络读写, 命令执行还在主线程
  ├─ ④ 数据结构(全内存)
  │     ├─ string / list / hash / set / zset / stream / module
  │     └─ 过期 + 淘汰(LRU/LFU/TTL)
  ├─ ⑤ 持久化
  │     ├─ RDB: 子进程 fork + COW 快照, fork 时主线程暂停几十 ms~几 s
  │     └─ AOF: 主线程 append + 后台 fsync
  ├─ ⑥ 主从复制
  │     ├─ 全量: RDB 文件传输(网络 + 磁盘大)
  │     └─ 增量: replication backlog 环形 buffer
  └─ ⑦ 集群(Cluster Mode)
        ├─ 16384 slot 分片
        └─ Gossip 协议(节点间互探)
```

## 4 个资源轴 + 1 个使用模式

| 轴 | 跟什么相关 | 主参数 | 直接症状 |
|---|---|---|---|
| **① 内存** | **唯一硬上限**。Redis 全数据在内存,maxmemory 撑爆要么 OOM 要么开始淘汰 | `maxmemory`、`maxmemory-policy`(`allkeys-lru` / `volatile-lru` / `noeviction` / `allkeys-lfu`) | `used_memory_rss / maxmemory > 0.9` → 告警;`evicted_keys` 增长 → 命中率掉 |
| **② 单核 CPU + RTT** | Redis **单线程跑命令**,QPS 上限 ≈ `1 / 单命令耗时`。本地 10w-15w QPS,跨机房带宽充足下也只 1-3w QPS(RTT 主导) | `cpu` 主频、网络 RTT、命令复杂度(`KEYS *` / `SMEMBERS bigset` 直接卡死) | `slowlog` 出现 ms 级命令、`INFO commandstats` 平均 usec_per_call > 100us |
| **③ 网络** | 大 key / 大批返回(MGET 上千 key、HGETALL 大 hash)耗带宽和序列化时间 | 网卡带宽、`client-output-buffer-limit` | `output_list_length` 飙、客户端超时 |
| **④ 持久化 + Fork** | RDB 快照 fork 一次会冻结主线程几十 ms~几 s(内存越大越久),AOF rewrite 同理 | `save`、`appendfsync`、`auto-aof-rewrite-percentage` | `latest_fork_usec` > 500ms;业务超时尖刺 |
| **⑤ 使用模式(隐性最大)** | 用对了 1G 顶 100G;用错了 100G 顶 1G | 大 key、热 key、N+1 调用模式、是否用 pipeline | 单实例 used_memory 涨太快、单 key 几十 MB |

## 资源关系公式

```
QPS_max = min(
  1 / (单命令 CPU 时间 + RTT),                  # 单线程上限,这是关键
  网络带宽 / 平均请求字节数,                     # 大 key 时撞网络
  内存大小 / 平均 key 大小                       # 容量上限
)
```

**关键洞察**:Redis 单实例 QPS 物理上限 ~10w-15w(本地),想要更多 → **必须 Cluster 分片**,加内存解决不了 QPS,只能解决容量。

## 4 种典型部署模式 trade-off

| 模式 | 容量 | 可用性 | 横向扩展 | 复杂度 | 何时选 |
|---|---|---|---|---|---|
| **单机** | 受单机内存限 | 无 HA | 不能 | ★ | 测试 / 缓存丢了不要命的场景 |
| **主从 (replication)** | 单机内存限 | 主挂手动切 | 读可扩 | ★★ | 业务可容忍切换感知 |
| **Sentinel(哨兵)** | 单机内存限 | 自动 failover | 读可扩 | ★★★ | 中小业务 HA 首选,部署最简 |
| **Cluster(集群)** | 几乎无上限 | 自动 failover | 写也可扩(分片) | ★★★★ | 大数据量 / 高并发 / 跨机房 |

**选型逻辑**:数据量 < 32G 用 Sentinel(简单);> 64G 或单实例 QPS 不够用 Cluster。仓库内对应配置:
- [../docker/docker-compose/redis/cluster/](../docker/docker-compose/redis/cluster/) — Cluster 模板
- [../docker/docker-compose/redis/6node/](../docker/docker-compose/redis/6node/) — 单机集群变体
- [../docker/docker-compose/redis/bitnami/](../docker/docker-compose/redis/bitnami/) — 单机生产
- [../docker/docker-compose/redis/dev/](../docker/docker-compose/redis/dev/) — 无密码开发

## 实战:8C16G 单实例推荐配置

| 项 | 推荐 | 算法依据 |
|---|---|---|
| `maxmemory` | **10G** | 留 4G 给 fork COW + AOF buffer + 系统;**别配 16G**,fork 时 OS 没空间会爆 |
| `maxmemory-policy` | **`allkeys-lru`**(纯缓存) / **`volatile-lru`**(带持久数据) / **`noeviction`**(写入要可靠) | 看业务是缓存还是数据库 |
| `tcp-backlog` | **1024** | Linux somaxconn 同步调大(`net.core.somaxconn`) |
| `timeout` | **300** | 防止僵尸连接占资源 |
| `tcp-keepalive` | **60** | 跨 NAT / 云负载均衡时必须 |
| `save`(RDB) | **`save 3600 1 300 100 60 10000`** 或**关掉**走 AOF | 纯缓存可关 RDB 节约 fork 开销 |
| `appendonly` | **yes**(数据要可靠) / **no**(纯缓存) | 业务决定 |
| `appendfsync` | **`everysec`** | `always` 慢 10x;`no` 丢数据风险高 |
| `auto-aof-rewrite-percentage` | **100** + `auto-aof-rewrite-min-size 1GB` | 触发太频繁会卡 fork |
| `io-threads`(6.0+) | **4**(8 核机器) | 仅加速网络 IO,命令仍单线程 |
| `repl-backlog-size` | **256MB** | 主从断线重连兜底,太小走全量复制 |

## 关键 trade-off

| 选项 | A(可靠/简单) | B(性能优先) | 选哪个 |
|---|---|---|---|
| RDB vs AOF | RDB(快、紧凑) | AOF(秒级丢失) | **生产两个都开**(RDB 灾备 + AOF 实时) |
| `appendfsync` | `always` | `everysec` | 几乎**永远选 everysec**,`always` 性能损失太大 |
| 持久化 vs 性能 | 开 AOF | 全关 | **纯缓存层全关**(数据丢了重灌即可) |
| 集群方案 | Redis Cluster 原生 | Codis / Twemproxy + 代理 | 6.0+ 选 Cluster 原生(运维少一层) |
| `maxmemory-policy` | `noeviction` | `allkeys-lru` | **缓存 lru,数据 noeviction**(数据库属性时 evict 是灾难) |
| pipeline vs 单命令 | 单条 | pipeline 批量 | **超过 10 个命令一定要 pipeline**,RTT 省 90%+ |
| 读写分离 | 都走 master | 读走 replica | **慎用 replica 读**:Redis 异步复制,可能读到旧数据 |

## 可复用排障清单(随时抄)

```bash
# ===== ① 内存全景 =====
redis-cli INFO memory | grep -E 'used_memory|maxmemory|mem_fragmentation|evicted_keys'
# used_memory_rss / maxmemory > 0.9 立即扩
# mem_fragmentation_ratio > 1.5 → 重启实例或开 activedefrag

# ===== ② 单线程命令分布 =====
redis-cli INFO commandstats | head -30
# usec_per_call > 1000(1ms) 的命令优先优化
# 关注 KEYS / SMEMBERS / HGETALL / ZRANGE 等 O(N)

# ===== ③ 慢日志 =====
redis-cli SLOWLOG GET 50
redis-cli CONFIG SET slowlog-log-slower-than 10000  # > 10ms 记录

# ===== ④ 大 key 扫描 =====
redis-cli --bigkeys
# 或针对性: redis-cli --memkeys --memkeys-samples 1000
# 单 key > 10MB 一律拆分

# ===== ⑤ 热 key 扫描 =====
redis-cli --hotkeys  # 需要 maxmemory-policy 是 LFU
# 或抓包: redis-faina (https://github.com/facebookarchive/redis-faina)

# ===== ⑥ Fork 延迟 =====
redis-cli INFO stats | grep -E 'latest_fork|total_forks'
# latest_fork_usec > 500000 (500ms) → 业务感知尖刺

# ===== ⑦ 持久化状态 =====
redis-cli INFO persistence | grep -E 'rdb_last_bgsave_status|aof_enabled|aof_last_rewrite|aof_pending'

# ===== ⑧ 客户端连接 =====
redis-cli CLIENT LIST | wc -l
redis-cli INFO clients | grep -E 'connected_clients|blocked_clients|maxclients'

# ===== ⑨ 主从复制 =====
redis-cli INFO replication
# master_link_status:up + slave_repl_offset 跟 master 接近

# ===== ⑩ Cluster 状态 =====
redis-cli CLUSTER INFO
redis-cli CLUSTER NODES
redis-cli --cluster check <host>:<port>
```

## 容器化(K8s)额外坑

| 坑 | 现象 | 修法 |
|---|---|---|
| **`vm.overcommit_memory`** 默认 0 → fork 失败 | `latest_fork_usec` 一会儿 -1,RDB save 报 "Can't save in background" | initContainer 跑 `sysctl -w vm.overcommit_memory=1`,或宿主机 `/etc/sysctl.conf` |
| **`net.core.somaxconn`** 默认 128 太小 | 业务并发上来 Redis backlog 满,新连接被拒 | initContainer `sysctl -w net.core.somaxconn=1024` + Redis 配同值 |
| **`THP`(透明大页)开着** | Redis 启动日志报 `WARNING you have Transparent Huge Pages (THP) support enabled`,fork 慢且内存暴涨 | DaemonSet 关 THP: `echo never > /sys/kernel/mm/transparent_hugepage/enabled` |
| **K8s `requests.memory` < 实际使用** | OOMKilled 半夜被杀 | `requests.memory == limits.memory`,且**大于 `maxmemory + fork 预留`** |
| **Cluster bus 端口** | 集群节点互探用 `port + 10000`(默认 16379),K8s 防火墙挡掉 | NetworkPolicy / SecurityGroup 同时放 `6379` 和 `16379` |
| **PVC `accessMode: RWO`** + 重调度 | Pod 飘到另一个节点起不来 | 用 local-path / longhorn(支持 RWO 但跨节点 detach 干净)或 RWX SC |

## 真实案例:24G 实例 fork 60s(机械盘集群)

### 现象
- 集群每台 24G,`used_memory` 10+G(还有空间)
- `latest_fork_usec` ~ 60s(正常 24G 应 < 500ms)
- 机械盘
- 业务侧 P99 出现 60s 尖刺,跟 BGSAVE 时间对应

### 解读 — fork 时间 vs RDB dump 时间

| 阶段 | 时长决定因素 | 主线程阻塞? |
|---|---|---|
| **`fork()` 系统调用** | 页表 + THP split + overcommit 检查,**跟磁盘无关** | **是**(业务停 60s 在这里) |
| RDB dump | 磁盘顺序写带宽(机械盘 ~100MB/s) | 否(子进程跑) |

混淆这两个会找错根因。**60s = fork() 系统调用本身**,机械盘只是次要因素。

### 根因(按概率排序)

| 根因 | 验证 | 占比 |
|---|---|---|
| 🔴 **THP 开着 + 高写入** | `cat /sys/kernel/mm/transparent_hugepage/enabled` 含 `[always]` | ~70% |
| 🔴 **`vm.overcommit_memory=0`** | `sysctl vm.overcommit_memory` = 0 | ~25% |
| 🟡 swap 在跑 | `free -m` Swap used > 0 | <5% |
| 🟡 内核老 / NUMA 跨 socket | `uname -r` < 3.10 | 极少 |

`fork()` 内部:24G / 2MB = 12,288 个大页,**THP 开时每个都要 split 成 512 个 4K 页 + TLB shootdown**,这一步可以从毫秒级涨到几十秒。

### 修复脚本(已验证)

```bash
# === 1. 关 THP(临时即时 + 永久 systemd)===
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=redis.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '\
  echo never > /sys/kernel/mm/transparent_hugepage/enabled && \
  echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
systemctl daemon-reload
systemctl enable --now disable-thp.service

# === 2. overcommit / somaxconn / swappiness ===
cat >> /etc/sysctl.d/99-redis.conf <<'EOF'
vm.overcommit_memory = 1
net.core.somaxconn = 1024
vm.swappiness = 1
EOF
sysctl --system

# === 3. Redis 配置 - 机械盘场景 ===
# 纯缓存: 直接关 RDB
redis-cli CONFIG SET save ""
redis-cli CONFIG REWRITE

# 或数据库: 降频
redis-cli CONFIG SET save "21600 1000000"
redis-cli CONFIG SET auto-aof-rewrite-percentage 200
redis-cli CONFIG SET auto-aof-rewrite-min-size 4gb
redis-cli CONFIG SET repl-diskless-sync yes
redis-cli CONFIG SET repl-diskless-sync-delay 5
redis-cli CONFIG REWRITE
```

### 验证

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled   # 期望 [never]
sysctl vm.overcommit_memory                        # 期望 1

redis-cli BGSAVE && sleep 5
redis-cli INFO stats | grep latest_fork_usec
# 期望从 60000000 → < 500000(500ms 内)
```

### 长期改进路径

1. **机械盘 → SSD/NVMe**:RDB dump 不再卡 IO,AOF rewrite 不再抢带宽
2. **24G 实例 → 拆成 8G × 3 分片**:fork 各自小,Cluster 横向扩展
3. **diskless replication** 已开,主从全量同步不写 RDB 到本地盘

### 级联灾难:fork 60s → 误主从切换 → 数据丢

fork 60s 不止业务卡 60s,**几乎必然触发集群误切换**,这才是真正的灾难。

#### 完整时间线

```
T+0s    主节点 fork() 开始 → 主线程被内核暂停 → 心跳停发
T+15s   ❶ cluster-node-timeout(默认 15s)触发,其他 master 标 PFAIL
T+~17s  ❷ 多数 master 判定 FAIL → replica 启动 failover election
T+~20s  ❸ 新 master 接管,客户端收 MOVED 重定向
T+60s   ❹ 原主 fork() 返回 → 发现自己已是 replica → 丢弃内存做全量同步
T+几分钟 ❺ 机械盘 + 10G+ RDB 全量同步又卡几分钟才恢复
```

**丢失数据**:
- fork 期间业务写入被新 master 接走,跟旧主可能有窗口差
- 旧主 replication backlog 里没发出去的数据 → **永久丢失**

#### 根因 — 三个默认值碰撞

| 参数 | 默认 | 问题 |
|---|---|---|
| `cluster-node-timeout` | **15000 ms** | fork 60s 必超过,误切换不可避免 |
| `cluster-require-full-coverage` | **yes** | 一个 slot 没主整个集群拒绝服务 |
| `min-replicas-to-write` (≥8.0) / `min-slaves-to-write` (<5.0) | **0** | 主库被孤立时仍接受写入,**脑裂丢数据** |

#### 修复 — 集群参数加固(配合 fork 根治一起做)

```bash
# 调大 cluster-node-timeout 容忍长 fork(留裕度调到 90s)
redis-cli CONFIG SET cluster-node-timeout 90000

# 防脑裂:主库失去所有 replica 或 replica 落后 > 10s 时停写
# 业务侧会收到 NOREPLICAS 错误,但不会丢数据
redis-cli CONFIG SET min-replicas-to-write 1
redis-cli CONFIG SET min-replicas-max-lag 10

# 部分 slot 不可用时其他 slot 继续服务(看业务接受度)
redis-cli CONFIG SET cluster-require-full-coverage no

redis-cli CONFIG REWRITE
```

#### 一次性给集群所有节点改

```bash
# 从 seed 节点拿到所有 endpoint,逐个 CONFIG SET
SEED_HOST=<your-seed-host>
SEED_PORT=6379
for node in $(redis-cli -h $SEED_HOST -p $SEED_PORT CLUSTER NODES | awk '{print $2}' | cut -d@ -f1); do
  HOST=${node%:*}; PORT=${node#*:}
  echo "[$HOST:$PORT] applying..."
  redis-cli -h $HOST -p $PORT CONFIG SET cluster-node-timeout 90000
  redis-cli -h $HOST -p $PORT CONFIG SET min-replicas-to-write 1
  redis-cli -h $HOST -p $PORT CONFIG SET min-replicas-max-lag 10
  redis-cli -h $HOST -p $PORT CONFIG SET cluster-require-full-coverage no
  redis-cli -h $HOST -p $PORT CONFIG REWRITE
done
```

#### 验证

```bash
redis-cli CONFIG GET cluster-node-timeout         # 期望 90000
redis-cli CONFIG GET min-replicas-*               # 期望 1 / 10
redis-cli CLUSTER NODES | awk '$3 ~ /fail/'       # 期望空,无 failed 节点
redis-cli --cluster check $SEED_HOST:$SEED_PORT   # 期望 [OK] All nodes agree
```

#### 选型对比 — 防误切换三种力度

| 方案 | 效果 | 副作用 | 选 |
|---|---|---|---|
| **消除 fork 60s 本身** | 根治 | 无 | ✅ 必做(见上面"修复脚本") |
| 调大 `cluster-node-timeout` 到 60-90s | fork 期间集群不慌 | 真故障切换变慢 | ✅ 兜底 |
| `cluster-replica-no-failover yes` | 完全禁用自动 failover | 真故障要人工切 | 🟡 只在受不了误切换 + 有 7x24 oncall 时用 |
| `min-replicas-to-write 1` + `max-lag 10` | 防脑裂 | 网络抖业务报 NOREPLICAS | ✅ 跨机房必做 |

## 一句话总结

> **Redis 性能 = 内存(容量) × 单核 CPU+RTT(QPS) × 不被大 key/热 key/Fork 拖死(实际表现)**。
>
> 想加 QPS 唯一办法是 **Cluster 分片** 或 **业务侧 pipeline**;想加容量直接扩内存。**单实例不要超过 32G**,fork 太痛苦。

## 相关入口

- [../docker/docker-compose/redis/](../docker/docker-compose/redis/) — 各种部署模板(1node / 6node / cluster / bitnami / dev / exporter)
- [../kubernetes/redis/](../kubernetes/redis/) — K8s 部署
- [../mysql/capacity-planning.md](../mysql/capacity-planning.md) — 配套的 MySQL 容量规划(同样格式,对照看)
