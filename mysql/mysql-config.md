### MySQL 调优参考

#### 时区
数据库时区应与业务服务保持一致，推荐使用东八区。

```ini
# 容器启动时设置 TZ 环境变量
-e TZ=Asia/Shanghai

# 或在 my.cnf 中设置
default-time-zone = '+8:00'
```

#### 连接数
取决于服务器内存，一般按每个连接 ≈ 2MB 估算：

```ini
# 最大连接数（默认 151）
max_connections = 800
# 连接超时，单位秒，建议 300（5分钟），避免僵尸连接耗尽连接池
wait_timeout = 300
interactive_timeout = 300
# 最大错误连接数，防止暴力破解打满连接
max_connect_errors = 1000
```

#### 缓存 & Buffer

最关键的是 `innodb_buffer_pool_size`，通常设为物理内存的 **60%-80%**：

```ini
# 假设服务器 16GB 内存，缓冲池设为 10GB
innodb_buffer_pool_size = 10G
# 缓冲池实例数，减少锁竞争（默认 1，建议 4 或 8）
innodb_buffer_pool_instances = 4
# 日志缓冲区大小（默认 16M，写入频繁可适当加大）
innodb_log_buffer_size = 64M
# 每个日志文件大小（默认 48M，建议 1G-2G）
innodb_log_file_size = 1G
# 日志文件组数量（默认 2）
innodb_log_files_in_group = 2
# 排序缓冲区（每个 session 分配，不宜过大）
sort_buffer_size = 4M
join_buffer_size = 4M
# 表缓存
table_open_cache = 2000
table_definition_cache = 2000
```

#### 数据安全（双 1 配置）

保证数据不丢最关键的两个参数，但会降低写入性能（约 3-5 倍）：

```ini
# 每次事务提交都刷盘
sync_binlog = 1
innodb_flush_log_at_trx_commit = 1
```

如果追求写入性能且能接受秒级丢数，可将 `innodb_flush_log_at_trx_commit` 改为 2。

#### 其他需要注意的

| 参数 | 说明 | 建议值 |
|---|---|---|
| `max_allowed_packet` | 最大允许数据包 | 128M-1G（大字段/备份需要） |
| `innodb_lock_wait_timeout` | 行锁等待超时（秒） | 10-30 |
| `tmp_table_size` / `max_heap_table_size` | 内存临时表大小 | 64M-256M |
| `long_query_time` | 慢查询阈值（秒） | 1-3 |
| `expire_logs_days` / `binlog_expire_logs_seconds` | binlog 过期时间 | 7-14 天 |
| `character_set_server` | 字符集 | `utf8mb4`（推荐，支持 emoji） |
| `autocommit` | 自动提交 | 1（默认，业务中注意显式事务） |

慢查询日志建议开启：

```ini
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
log_queries_not_using_indexes = 1
```

---

## MySQL InnoDB Cluster（mysqlsh 管理）

推荐使用 MySQL Shell + Group Replication 替代传统主从复制，具备自动故障转移。

### 架构

```
MySQL Router ← → MySQL Shell (admin)
                    ↓
┌─────────┬─────────┬─────────┐
│ MySQL1  │ MySQL2  │ MySQL3  │
│ Primary │ Secondary│Secondary│
└─────────┴─────────┴─────────┘
  Group Replication（单主模式）
```

### 1. 配置要求

- 至少 3 个节点（奇数，用于 PAXOS 投票）
- 每个节点配置静态 hostname，确保互访
- 关闭防火墙或放通 3306、33060、33061 端口

### 2. 各节点 my.cnf

> ⚠️ **部署到新机器时，标注了 `# @update` 的参数需要按实际情况修改。**

```ini
[mysqld]
# @update 每个节点唯一（1/2/3...）
server-id=1
bind-address=0.0.0.0
sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
wait_timeout = 600
# @update 根据实际时区修改
default-time-zone = 'Asia/Shanghai'
interactive_timeout = 600
max_allowed_packet = 1G
net_read_timeout   = 600
net_write_timeout  = 600
max_connections = 2000
# @update 根据机器内存调整，物理内存 60%-80%
innodb_buffer_pool_size = 8G
innodb_buffer_pool_instances = 4
slow_query_log = 1
slow_query_log_file = /var/lib/mysql/mysql-slow.log
long_query_time = 1
log_output = FILE

gtid_mode=ON
enforce_gtid_consistency=ON

log_bin=mysql-bin
binlog_format=ROW
log_slave_updates=ON

transaction_write_set_extraction=XXHASH64

# @update 所有节点相同，用 uuidgen 生成
loose-group_replication_group_name="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
loose-group_replication_start_on_boot=OFF
# @update 本机 IP + 33061（组通信端口）
loose-group_replication_local_address="192.168.100.24:33061"
# @update 所有节点 IP:33061
loose-group_replication_group_seeds="192.168.100.24:33061,192.168.100.25:33061,192.168.100.26:33061"
loose-group_replication_bootstrap_group=OFF

loose-group_replication_single_primary_mode=ON
loose-group_replication_enforce_update_everywhere_checks=OFF

datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock

log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid
```

### 3. 使用 mysqlsh 部署集群

```bash
# 安装 MySQL Shell
# MySQL 官网下载对应版本 mysql-shell 包
# https://dev.mysql.com/downloads/shell/

# 连接第一个实例
mysqlsh root@10.0.0.1:3306
```

```js
// 在 mysqlsh JS 模式下执行

// 1. 配置实例（每个节点逐一执行）
dba.configureInstance('root@10.0.0.1:3306', {password: 'password'})
dba.configureInstance('root@10.0.0.2:3306', {password: 'password'})
dba.configureInstance('root@10.0.0.3:3306', {password: 'password'})

// 2. 创建集群（在第一个节点执行）
var cluster = dba.createCluster('myCluster', {adoptFromGR: false})

// 3. 添加其余节点
cluster.addInstance('root@10.0.0.2:3306', {password: 'password'})
cluster.addInstance('root@10.0.0.3:3306', {password: 'password'})

// 4. 检查状态
cluster.status()
```

### 4. 部署 MySQL Router

在应用服务器上部署 Router，提供读写分离和负载均衡：

```bash
# 安装 MySQL Router
# https://dev.mysql.com/downloads/router/

# 引导配置（指定任一集群节点即可自动发现，用户名密码为数据库 root）
# @update --user=mysqlrouter 为系统用户，可根据需要修改
mysqlrouter --bootstrap root@10.0.0.1:3306 --user=mysqlrouter

# 启动 Router
systemctl start mysqlrouter
```

> ⚠️ `--bootstrap` 会自动生成 Router 配置文件，其中 `router_id`、`user`（MySQL 账号）、SSL 证书路径等由引导过程自动填写，**无需手动修改**。
>
> 需要确认的参数：
> - `max_total_connections` / `max_connections` — 根据并发量调整
> - `connect_timeout` / `read_timeout` — 根据网络情况调整
> - `ttl` — metadata 刷新间隔，网络稳定可适当加大

Router 默认端口：

| 端口 | 用途 |
|---|---|
| 6446 | 读写端口（主库） |
| 6447 | 只读端口（从库） |

应用连接方式：

```text
# 读写
jdbc:mysql://10.0.0.10:6446/dbname

# 只读
jdbc:mysql://10.0.0.10:6447/dbname
```

### Router 连接池与超时配置

`--bootstrap` 后生成 `/etc/mysqlrouter/mysqlrouter.conf`，核心参数如下：

> ⚠️ 标注了 `# @update` 的参数根据环境调整；其余由 `--bootstrap` 自动生成，无需手动修改。

```ini
[DEFAULT]
user=mysqlrouter
logging_folder=/etc/mysqlrouter/log
runtime_folder=/etc/mysqlrouter/run
data_folder=/etc/mysqlrouter/data
keyring_path=/etc/mysqlrouter/data/keyring
master_key_path=/etc/mysqlrouter/mysqlrouter.key
# @update 网络延迟高可加大
connect_timeout=5
# @update 大查询慢可加大
read_timeout=30
# @update 根据并发量调整
max_total_connections=4000
# @update 同上
max_connections=4000
dynamic_state=/etc/mysqlrouter/data/state.json
client_ssl_cert=/etc/mysqlrouter/data/router-cert.pem
client_ssl_key=/etc/mysqlrouter/data/router-key.pem
client_ssl_mode=PREFERRED
server_ssl_mode=AS_CLIENT
server_ssl_verify=DISABLED
unknown_config_option=error

[logger]
level=INFO

[metadata_cache:bootstrap]
cluster_type=gr
# @update 多 Router 实例时需唯一
router_id=1
user=mysql_router1_bayywcj                       # bootstrap 自动生成，无需修改
metadata_cluster=myCluster
# @update metadata 缓存刷新秒数
ttl=0.5
auth_cache_ttl=-1
auth_cache_refresh_interval=2
use_gr_notifications=0

[routing:bootstrap_rw]
bind_address=0.0.0.0
bind_port=6446                                   # 读写端口（应用连接此端口）
destinations=metadata-cache://myCluster/?role=PRIMARY
routing_strategy=first-available
protocol=classic
# @update 与 DEFAULT 保持一致
max_connections=4000

[routing:bootstrap_ro]
bind_address=0.0.0.0
bind_port=6447                                   # 只读端口（应用连接）
destinations=metadata-cache://myCluster/?role=SECONDARY
routing_strategy=round-robin-with-fallback
protocol=classic
max_connections=4000

[routing:bootstrap_x_rw]
bind_address=0.0.0.0
bind_port=6448                                   # X Protocol 读写
destinations=metadata-cache://myCluster/?role=PRIMARY
routing_strategy=first-available
protocol=x

[routing:bootstrap_x_ro]
bind_address=0.0.0.0
bind_port=6449                                   # X Protocol 只读
destinations=metadata-cache://myCluster/?role=SECONDARY
routing_strategy=round-robin-with-fallback
protocol=x

[http_server]
port=8443
ssl=1
ssl_cert=/etc/mysqlrouter/data/router-cert.pem
ssl_key=/etc/mysqlrouter/data/router-key.pem

[http_auth_realm:default_auth_realm]
backend=default_auth_backend
method=basic
name=default_realm

[rest_router]
require_realm=default_auth_realm

[rest_api]

[http_auth_backend:default_auth_backend]
backend=metadata_cache

[rest_routing]
require_realm=default_auth_realm

[rest_metadata_cache]
require_realm=default_auth_realm
```

**关键说明：**

| 参数 | 作用 | 参考值 |
|---|---|---|
| `max_total_connections` | Router 能接受的最大客户端连接数 | 4000 |
| `max_connections` | 每个 routing 端口的最大连接数 | 4000 |
| `connect_timeout` | 到 MySQL 后端连接超时（秒） | 5 |
| `read_timeout` | 读超时（秒） | 30 |
| `ttl` | metadata 缓存刷新间隔（秒） | 0.5 |

**连接数计算公式：**

```
Router max_total_connections ≤ MySQL max_connections × 节点数
```

示例（3 节点集群，MySQL max_connections=2000，Router max_total_connections=4000）：

```text
4000 ≤ 2000 × 3 = 6000 ✅   # Router 不会打满 MySQL
```

重启 Router 生效：

```bash
systemctl restart mysqlrouter
```

### 5. 日常管理命令

```js
// 连接 shell 后
var cluster = dba.getCluster('myCluster')

// 查看状态
cluster.status()
cluster.status({extended: 1})

// 描述拓扑
cluster.describe()

// 主从切换（switchover，计划内）
cluster.switchPrimaryTo('10.0.0.2:3306')

// 故障转移（failover）
// Group Replication 自动选举，无需手动操作

// 移除实例
cluster.removeInstance('root@10.0.0.3:3306')

// 重新加入实例
cluster.rejoinInstance('root@10.0.0.3:3306')

// 解散集群
cluster.dissolve()
```


### 6. InnoDB Cluster 性能与注意事项

#### 时区

三个节点需统一时区，否则复制可能出问题。

```ini
# my.cnf
default-time-zone = '+8:00'
```

或容器环境变量：

```yaml
environment:
  - TZ=Asia/Shanghai
```

#### Buffer Pool 设置

每个节点独立设置，依据单机内存配置：

```ini
innodb_buffer_pool_size = 10G           # 物理内存的 60%-80%
innodb_buffer_pool_instances = 4        # 减少锁竞争
innodb_log_file_size = 1G               # 较大值减少日志切换频率
innodb_log_buffer_size = 64M
```

**注意**：Group Replication 的节点间认证会额外消耗 CPU 和内存，`innodb_buffer_pool_size` 建议比同等单机实例稍低 10%-15%。

#### 大事务处理

Group Replication 的事务**必须在所有节点上认证并应用**，大事务严重影响集群吞吐。

```sql
-- 查看正在认证的事务大小
SELECT * FROM performance_schema.replication_group_member_stats\G

-- 拆分大事务
-- ❌ 避免：单条 INSERT ... SELECT 影响全表
-- ✅ 改为：分页分批提交，每批 1000-5000 行
```

**经验值**：

| 事务大小 | 影响 |
|---|---|
| < 1MB | 正常 |
| 1MB - 100MB | 可能造成复制延迟 |
| > 100MB | 极可能导致全集群延迟飙升，尽量避免 |

监测事务大小：

```sql
-- 查看当前 binlog 中最大事务（单位：字节）
SHOW BINLOG EVENTS IN 'mysql-bin.000001' LIMIT 10;
```

#### 网络延迟与超时

节点间延迟是 InnoDB Cluster 最大的性能瓶颈，所有写入事务都要经过 Group Replication 的共识阶段。

```ini
# my.cnf — 根据实际延迟调整
loose-group_replication_poll_spin_loops = 20000
loose-group_replication_compression_threshold = 1048576   # 大事务压缩后再复制
```

| 节点间延迟 | 预期写入 TPS | 建议 |
|---|---|---|
| < 1ms | 10000+ | 同机房部署 |
| 1-5ms | 3000-10000 | 同区域可用区 |
| > 5ms | < 3000 | 考虑异步复制方案 |

如果节点跨机房延迟较高，考虑调大 Group Replication 超时：

```ini
loose-group_replication_member_expel_timeout = 10   # 默认 5 秒
```

#### 备份与恢复

推荐使用 MySQL Shell 的 dump 工具：

```bash
# 全量导出（不会阻塞读写）
mysqlsh root@10.0.0.1:3306 -- util dumpInstance /backup/mysql --threads=4 --ocimds=0

# 全量导入
mysqlsh root@10.0.0.1:3306 -- util loadDump /backup/mysql --threads=4
```

#### 监控指标

```sql
-- Group Replication 状态
SELECT * FROM performance_schema.replication_group_members;
SELECT * FROM performance_schema.replication_group_member_stats;

-- 认证队列长度（堆积说明写入跟不上）
SELECT count_transactions_remote_in_applier_queue
FROM performance_schema.replication_group_member_stats;

-- 主从延迟
SELECT * FROM performance_schema.replication_applier_status_by_worker;
```

Shell 命令：

```bash
# 检查集群状态
cluster.status({extended: 1})

# 检查一致性
cluster.checkInstanceState('root@10.0.0.2:3306')
```
