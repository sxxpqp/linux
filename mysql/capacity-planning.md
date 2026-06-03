# MySQL 容量规划 / 性能瓶颈速查

> 任何 MySQL 性能问题先从这里入手 — **5 个资源轴 × 1 个 schema 设计**,任何一轴跑满 QPS 就停在那。
> 排障时直接复制粘贴下面的 SQL 清单。

## 完整请求链路

```
业务进程 (Java/Go/Python)
  ↓ ① 应用连接池 (HikariCP / druid / sqlx)
  ↓ TCP/3306
ProxySQL  ← 读写分离 + 池化 + 路由(可选)
  ↓ TCP/3306
MySQL Server 进程
  ├─ ② Connection thread        (内存: thread_stack 256KB/连接 + per-thread buffers)
  ├─ ③ Parser → Optimizer       (CPU 密集)
  ├─ ④ InnoDB Buffer Pool       (内存大头, 占 50-75% 物理内存)
  │     ├─ 命中:  纯内存 GB/s 级
  │     └─ miss:  走 ⑤ 磁盘
  ├─ ⑤ Redo Log (ib_logfile)    (磁盘 IOPS / fsync 延迟 → 决定写入 TPS)
  ├─ ⑥ Binlog                   (磁盘 + ⑦ 网络: 主从同步)
  └─ ⑦ Storage 层 (NVMe/SSD/HDD)
```

任何一层是瓶颈,上面的层都白搭。

## 5 个资源轴 + 1 个设计轴

| 轴 | 跟什么相关 | 主参数 | 直接症状 |
|---|---|---|---|
| **① 内存** | `innodb_buffer_pool_size` 占大头(50-75% 物理内存)+ 每连接 ~2-4MB + tmp_table 大查询临时膨胀 | `innodb_buffer_pool_size`、per-thread buffers(sort/join/read/tmp_table) | buffer pool hit rate < 99% → 大量磁盘 IO,SLA 抖 |
| **② CPU** | 复杂 SQL(JOIN/GROUP BY/聚合/函数) = CPU 密集;简单 PK 查询基本不耗 CPU | 核心数;`innodb_thread_concurrency`(8.0 留 0) | `Threads_running` 高 + `top` 看 mysqld %CPU 持续 > 80% |
| **③ 连接数** | 业务并发 + 应用连接池配置;**连接本身耗内存**,1000 个连接 ≈ 2-4GB | `max_connections`、`thread_cache_size`、`back_log` | `Threads_connected` 接近 `max_connections` → 新连接被拒 |
| **④ 磁盘 IO** | 数据 miss buffer pool 后随机读;redo/binlog 写 fsync 延迟决定事务提交速度 | `innodb_io_capacity`、`innodb_flush_log_at_trx_commit`、`sync_binlog`、`innodb_log_file_size` | `iostat -x` await > 10ms,`Innodb_log_waits` 增长 |
| **⑤ 网络** | 大结果集传输 + 主从 binlog 复制(跨机房) | 网卡带宽 / RTT | `Seconds_Behind_Master` 持续 > 0,大查询慢但 mysql 自己不忙 |
| **⑥ Schema/索引(隐性最大)** | 索引选对了,buffer pool 利用率高;选错了把 buffer pool 撑爆 | 主键 / 二级索引 / 字段类型 | EXPLAIN 出现 type=ALL / Using filesort / Using temporary |

## 资源关系公式

```
QPS_max = min(
  CPU 核数 × 单核 QPS / 单查询 CPU 时间,        # CPU 上限
  buffer pool 命中后内存读 ~= 不是瓶颈,         # 内存读上限(几乎无限)
  磁盘 IOPS / (1 - buffer_hit_rate),            # IO 上限(关键!)
  网络带宽 / 平均响应字节数,                     # 网络上限
  max_connections × (1 / 平均查询时间)           # 连接并发上限
)
```

**关键洞察**:大多数线上 MySQL 性能问题的根因都是 **buffer pool 命中率不够** → 走磁盘 → IOPS 撑不住 → 雪崩。所以**内存是 MySQL 第一资源**,不是 CPU。

## 实战:8C16G 单实例推荐配置

| 项 | 推荐 | 算法依据 |
|---|---|---|
| `innodb_buffer_pool_size` | **10G**(62.5%) | 16 × 0.625 |
| `max_connections` | **500** | 留 ~3G 给连接(500 × ~4MB)+ 2G OS |
| `innodb_log_file_size` | **1G** | 兼顾 redo 写性能 vs crash recovery 时间 |
| `innodb_io_capacity` | **2000** | NVMe;SATA SSD 用 1000;HDD 用 200 |
| `innodb_flush_log_at_trx_commit` | **1**(主)/ **2**(从) | 主强一致;从可靠 OS cache 换性能 |
| `sync_binlog` | **1**(主)/ **0**(从) | 同上 |
| `thread_cache_size` | **100** | 避免频繁创建连接线程 |
| `tmp_table_size`、`max_heap_table_size` | **64M** | 太大单连接吃内存爆 |
| `innodb_buffer_pool_instances` | **8**(当 buffer pool ≥ 8G) | 减锁竞争 |

## 关键 trade-off

| 选项 | A(保守/默认) | B(性能优先) | 选哪个 |
|---|---|---|---|
| `innodb_flush_log_at_trx_commit` | `1`(每事务 fsync) | `2`(OS write,1s 一次 fsync) | **主库选 A** 保数据;从库/分析库选 B 提性能 |
| `sync_binlog` | `1`(每写 fsync) | `0`(OS 决定) | 同上 |
| 连接池在哪 | 应用侧(HikariCP) | 中间层(ProxySQL) | 单服务选 A;多服务/读写分离选 B;**两层都做最稳** |
| `innodb_buffer_pool_instances` | 1 个 | 8 个(>= 1G/instance) | **buffer pool ≥ 8G 选 B** 减锁竞争 |
| 主从一致性 | 半同步(semi-sync) | Paxos/Raft(apecloud-mysql / WeSQL) | 兼容性优先 A;金融级强一致选 B,见 [../kubernetes/kubeblocks/mysql/paxos/](../kubernetes/kubeblocks/mysql/paxos/) |

## 可复用排障 SQL(随时抄)

```sql
-- ===== ① 内存:buffer pool 命中率(必须看!) =====
SELECT
  (1 -
    SUM(IF(VARIABLE_NAME='Innodb_buffer_pool_reads', VARIABLE_VALUE, 0)) /
    SUM(IF(VARIABLE_NAME='Innodb_buffer_pool_read_requests', VARIABLE_VALUE, 0))
  ) * 100 AS buffer_pool_hit_rate_pct
FROM performance_schema.global_status
WHERE VARIABLE_NAME IN ('Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests');
-- 目标 > 99%;< 95% 立即扩内存

-- ===== ② CPU:运行中的 SQL =====
SELECT THREAD_ID, PROCESSLIST_USER, PROCESSLIST_HOST, PROCESSLIST_DB,
       PROCESSLIST_COMMAND, PROCESSLIST_TIME, PROCESSLIST_STATE, PROCESSLIST_INFO
FROM performance_schema.threads
WHERE PROCESSLIST_STATE IS NOT NULL AND PROCESSLIST_COMMAND != 'Sleep'
ORDER BY PROCESSLIST_TIME DESC LIMIT 20;

-- ===== ③ 连接数 =====
SHOW STATUS WHERE Variable_name IN
  ('Threads_connected','Threads_running','Max_used_connections','Aborted_connects');
-- Max_used_connections / max_connections > 0.8 → 扩或加池

-- ===== ④ IO:redo log 等待 =====
SHOW STATUS LIKE 'Innodb_log_waits';
-- > 0 且增长 → innodb_log_buffer_size 不够或磁盘慢

-- ===== ⑤ 主从延迟 =====
SHOW REPLICA STATUS\G   -- 8.0+;老版本 SHOW SLAVE STATUS
-- Seconds_Behind_Source 持续 > 0 → 网络 or 大事务 or 单线程复制

-- ===== ⑥ 锁等待(死锁/长事务) =====
SHOW ENGINE INNODB STATUS\G   -- LATEST DETECTED DEADLOCK / TRANSACTIONS 段
SELECT * FROM performance_schema.data_lock_waits;
SELECT trx_id, trx_state, trx_started, trx_mysql_thread_id, trx_query
FROM information_schema.innodb_trx
WHERE TIME_TO_SEC(TIMEDIFF(NOW(), trx_started)) > 60;  -- 超过 60s 的长事务

-- ===== ⑦ schema:慢查询 + 索引利用 =====
EXPLAIN ANALYZE <你的 SQL>;
-- type=ALL / rows 巨大 / Using filesort / Using temporary → 缺索引
```

## 容器化(K8s)额外坑

| 坑 | 现象 | 修法 |
|---|---|---|
| MySQL 默认按宿主机算内存,但 cgroup 限制更小 | buffer pool 配 10G,但 pod limits 8G → OOMKilled | K8s Pod 必须设 `resources.limits.memory`,MySQL 配 `innodb_buffer_pool_size` 显式按 limit 算 |
| `nproc` 看宿主机核数,but cgroup 限了 | `innodb_read_io_threads` 配 32,实际只有 4 核 | 显式配 `innodb_io_threads`,不依赖默认 |
| K8s 滚动更新导致连接抖动 | 应用连接池里全是已 closed 连接 | `terminationGracePeriodSeconds: 30` + 应用侧连接 keepalive 检测 |
| NUMA 跨节点访问内存慢 50% | 大内存实例性能不稳定 | `numactl --interleave=all` 或 K8s NUMA-aware scheduler |

仓库内对应的 yaml 已经有这些考虑:
- [../kubernetes/kubeblocks/mysql/semisync/cluster.yaml](../kubernetes/kubeblocks/mysql/semisync/cluster.yaml)
- [../kubernetes/kubeblocks/mysql/paxos/cluster.yaml](../kubernetes/kubeblocks/mysql/paxos/cluster.yaml)

## 一句话总结

> **MySQL 性能 = 内存(命中率) × 磁盘 IOPS(miss 后兜底) × CPU(复杂查询) × 连接池设计(并发) × 网络(主从+大结果集) × schema(根本)**。
>
> 没钱加资源时,**先优化 schema/索引** 收益最大;然后才考虑加内存(扩 buffer pool),最后才升 SSD/换实例。

## 相关入口

- [mysql-config.md](mysql-config.md) — InnoDB Cluster 集群部署 + Router 连接池调优(生产推荐)
- [../kubernetes/kubeblocks/mysql/](../kubernetes/kubeblocks/mysql/) — K8s 上的 operator 部署(semisync / paxos 二选一)
- [../docker/docker-compose/mysql/](../docker/docker-compose/mysql/) — 单机测试模板
