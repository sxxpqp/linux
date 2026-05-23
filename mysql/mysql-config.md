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

```ini
[mysqld]
server_id = 1                                # 每个节点唯一
gtid_mode = ON
enforce-gtid-consistency = ON
binlog_checksum = NONE                       # Group Replication 要求

# Group Replication
plugin_load_add = group_replication
group_replication_group_name = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"  # UUID，每个集群固定
group_replication_start_on_boot = OFF
group_replication_bootstrap_group = OFF
group_replication_local_address = "10.0.0.1:33061"                     # 本机 IP:组通信端口
group_replication_group_seeds = "10.0.0.1:33061,10.0.0.2:33061,10.0.0.3:33061"
group_replication_ip_allowlist = "10.0.0.0/24"
group_replication_single_primary_mode = ON
group_replication_enforce_update_everywhere_checks = OFF

# 推荐
binlog_format = ROW
binlog_row_image = MINIMAL                    # 减少 binlog 体积
transaction_write_set_extraction = XXHASH64
loose-group_replication_recovery_get_public_key = ON

# 连接数 — 每个集群节点独立设置
max_connections = 800                         # 最大连接数（Router 会占用一部分）
max_connect_errors = 1000
wait_timeout = 300                            # 非交互连接超时（秒）
interactive_timeout = 300                     # 交互连接超时（秒）
net_read_timeout = 30                         # 读超时
net_write_timeout = 60                        # 写超时

# Group Replication 通信超时
loose-group_replication_communication_stack = XCOM
loose-group_replication_poll_spin_loops = 20000
loose-group_replication_compression_threshold = 1048576  # 1MB 以上压缩传输
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

# 引导配置（指定任一集群节点即可自动发现）
mysqlrouter --bootstrap root@10.0.0.1:3306 --user=mysqlrouter

# 启动 Router
systemctl start mysqlrouter
```

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

`--bootstrap` 后生成 `/etc/mysqlrouter/mysqlrouter.conf`，核心调优参数：

```ini
[DEFAULT]
# Router 自身的连接池，每个 worker 线程持有
client_connect_timeout = 10              # 客户端连接超时（秒）
max_total_connections = 500              # Router 最大客户端连接数
connect_timeout = 10                     # 到 MySQL 后端连接超时（秒）
read_timeout = 60                        # 读超时（秒）

[routing:primary]
bind_address = 0.0.0.0
bind_port = 6446
destinations = metadata-cache://myCluster?role=PRIMARY
routing_strategy = first-available                 # 主库：first-available
protocol = classic
# 后端连接池
connection_sharing = 1                             # 启用连接共享（默认关闭）
connection_sharing_delay = 5                       # 连接共享延迟（秒），用于事务开始前不共享
max_connect_errors = 100                           # 最大连续错误后标记不可达
client_ssl_mode = PREFERRED
server_ssl_mode = PREFERRED

[routing:secondary]
bind_address = 0.0.0.0
bind_port = 6447
destinations = metadata-cache://myCluster?role=SECONDARY
routing_strategy = round-robin                    # 从库：round-robin 负载均衡
protocol = classic
connection_sharing = 1
connection_sharing_delay = 5
max_connect_errors = 100
client_ssl_mode = PREFERRED
server_ssl_mode = PREFERRED

[connection_pool]
# 到 MySQL 后端的连接池
max_size = 50                                     # 每个后端最大连接数
max_idle_time = 120                               # 空闲连接最大存活秒数
max_lifetime_seconds = 1800                       # 连接最大生命周期（30分钟）
```

**关键说明：**

| 参数 | 作用 | 如果设太小 |
|---|---|---|
| `connection_sharing = 1` | 多个客户端复用同一后端连接 | — |
| `max_total_connections` | Router 能接受的最大连接数 | 客户端连接被拒绝 |
| `max_size` | Router 到每个 MySQL 后端的连接池大小 | 后端连接不足，请求排队 |
| `connection_sharing_delay` | 事务开始多久后不允许共享连接 | 短事务场景可设 1-3 |

**连接数计算公式：**

```
Router max_total_connections ≤ MySQL max_connections × 节点数
Router 连接池 max_size × 后端节点数 ≤ MySQL max_connections
```

示例（3 节点集群，MySQL max_connections=800）：

```text
Router max_total_connections = 800      # 可接受 800 个客户端
Router 连接池 max_size = 200            # 每个后端最多 200 连接
                                      # 200 × 3 = 600 ≤ 800 ✅
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

### 6. 传统主从复制（旧方案）

> 以下为传统异步/半同步复制方式，建议新项目改用上方 InnoDB Cluster。

### 主配置
```
[mysqld]
character_set_server=utf8
collation-server=utf8_general_ci
lower_case_table_names =1
max_connections = 800
max_connect_errors = 1000
max_allowed_packet= 1073741824
sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION
event_scheduler = 1
# 为服务器分配id，可以自定义，不区分大小，起标识作用。不同数据库节点分配不同的id
server_id=001
# 打开Mysql 日志，日志格式为二进制
log-bin=mysql-bin
# 可选项Mixed,Statement,Row，默认格式是 Statement，mixed混合Satement，ROW两种模式
binlog_format=row
# 日志过期时间
expire_logs_days  = 7
# 下面这两个参数非常重要
# 这个参数一般用在主主同步中，用来错开自增值, 防止键值冲突，master2上面改为2
auto_increment_offset = 1
# 这个参数一般用在主主同步中，用来错开自增值, 防止键值冲突
auto_increment_increment = 2
# 当启用时，服务器通过只允许执行可以使用GTID安全地记录的语句来强制GTID一致性。
enforce-gtid-consistency=true
# 启用基于GTID的复制，启用之前必须保证enforce-gtid-consistency=true
gtid_mode=ON
# 该选项让从库写入哪些来自于主库的更新，并把这些更新写入bin-log文件，一台服务器即做主库又做从库必须开启
log-slave-updates=true
# 只对新的session生效，为了关闭旧的session，需选择一个非业务时间段，重启源数据库并重置任务即可。
binlog_row_image  = full
##为了数据安全再配置
sync_binlog=1
innodb_flush_log_at_trx_commit=1
# 将函数复制到slave
log_bin_trust_function_creators = 1
# 需要复制的数据库名，如果复制多个数据库，重复设置这个选项即可
binlog-do-db = turingcloudx,turingcloudx_ac,turingcloudx_daily,turingcloudx_dataanalysis,turingcloudx_device,turingcloudx_mp,turingcloudx_overview,turingcloudx_pay,turingcloudx_video
# 以表形式保存
master_info_repository=TABLE
relay_log_info_repository=TABLE
relay_log_recovery=ON
```
### 从配置或者主配置
```
[mysqld]
# 主数据库端ID号，全局唯一，通常用IP地址最后一位
server_id = 10
# 开启二进制日志
log-bin = mysql-bin
# 该选项让从库写入哪些来自于主库的更新，并把这些更新写入bin-log文件，一台服务器即做主库又做从库必须开启
log-slave-updates=true
# 控制binlog的写入频率。每执行多少次事务写入一次(这个参数性能消耗很大，但可减小MySQL崩溃造成的损失)
sync_binlog = 1
innodb_flush_log_at_trx_commit=1
# 下面这两个参数非常重要
# 这个参数一般用在主主同步中，用来错开自增值, 防止键值冲突，master2上面改为2
auto_increment_offset = 2
# 这个参数一般用在主主同步中，用来错开自增值, 防止键值冲突
auto_increment_increment = 2
# 二进制日志自动删除的天数，默认值为0,表示“没有自动删除”，启动时和二进制日志循环时可能删除
expire_logs_days = 7
# 当启用时，服务器通过只允许执行可以使用GTID安全地记录的语句来强制GTID一致性。
enforce-gtid-consistency=true
# 启用基于GTID的复制，启用之前必须保证enforce-gtid-consistency=true
gtid_mode=ON
# 将函数复制到slave
log_bin_trust_function_creators = 1

# 以表形式保存
master_info_repository=TABLE
relay_log_info_repository=TABLE
relay_log_recovery=ON
# 只读配置
read_only=1
```

```
create user 'repl'@'%' identified by 'Iot@123456';
grant replication slave on *.* to 'repl'@'%';
flush privileges;
```

```
CHANGE MASTER TO MASTER_HOST = '139.198.123.207', MASTER_USER = 'slave', MASTER_PASSWORD = 'Iot@123456', MASTER_PORT = 33306, MASTER_AUTO_POSITION = 1, MASTER_RETRY_COUNT = 0
```

```
 change master to 
     master_host='192.168.1.221',
     master_port=3306,
     master_user='repl',
     master_password='vo7kphndxlzfr6u3',
 MASTER_AUTO_POSITION=1,
 GET_MASTER_PUBLIC_KEY=1;
```
在两个数据库实例中启动同步


```
start slave;
```
```
show slave status
```


### 主主复制企业级
```
mkdir -p /data/master
cat >docker-compose.yaml<<eof
version: '3'
services:
  mysql:
    restart: always
    image: mysql:5.7.30
    container_name: mysql-master
    volumes:
      - /data/master/mydir:/mydir
      - /data/master/datadir:/var/lib/mysql
      - /data/master/conf/my.cnf:/etc/mysql/my.cnf
      # 数据库还原目录 可将需要还原的sql文件放在这里
      - /data/master/source:/docker-entrypoint-initdb.d
    environment:
      - "MYSQL_ROOT_PASSWORD=Iot@123456"
      - "TZ=Asia/Shanghai"
    ports:
      # 使用宿主机的3306端口映射到容器的3306端口
      # 宿主机：容器
      - 3306:3306
  slave:
    restart: always
    image: mysql:5.7.30
    container_name: mysql-slave
    volumes:
      - /data/slave/mydir:/mydir
      - /data/slave/datadir:/var/lib/mysql
      - /data/slave/conf/my.cnf:/etc/mysql/my.cnf
      # 数据库还原目录 可将需要还原的sql文件放在这里
      - /data/slave/source:/docker-entrypoint-initdb.d
    environment:
      - "MYSQL_ROOT_PASSWORD=Iot@123456"
      - "TZ=Asia/Shanghai"
    ports:
      # 使用宿主机的3306端口映射到容器的3306端口
      # 宿主机：容器
      - 3307:3306
eof      
```
```         
cat>/data/master/conf/my.cnf<<eof
[mysqld]
user=mysql
default-storage-engine=INNODB
character-set-server=utf8
character-set-client-handshake=FALSE
collation-server=utf8_unicode_ci
init_connect='SET NAMES utf8'
server_id = 201                    #这里的ID号与从库上或者主库上的ID必须保证不一样
log-bin=mysql-bin                    #可以自定义 这里定义为 log-bin=/data/log-bin/log-bin-3310
binlog_format=row                    #主从复制模式
log-slave-updates=true                 #slave 更新是否记入日志
gtid-mode=on                                   # 启用gtid类型，否则就是普通的复制架构
enforce-gtid-consistency=true          #强制GTID 的一致性 
master-info-repository=TABLE        #主服信息记录库=表 /文件
relay-log-info-repository=TABLE    #中继日志信息记录库
sync-master-info=1                         #同步主库信息
slave-parallel-workers=10                #从服务器的SQL 线程数，要复制库数目相同
binlog-checksum=CRC32                   # 校验码 ，可以自定义
master-verify-checksum=1               #主服校验
slave-sql-verify-checksum=1             #从服校验
binlog-rows-query-log_events=1     #二进制日志详细记录事件
report-port=3307                             #提供复制报告端口，当前实例端口号
report-host=192.168.1.46                #提供复制报告主机，本机的ip地址
[client]
default-character-set=utf8
[mysql]
default-character-set=utf8
eof

mkdir -p /data/slave
cat>/data/slave/conf/my.cnf<<eof
[mysqld]
user=mysql
default-storage-engine=INNODB
character-set-server=utf8
character-set-client-handshake=FALSE
collation-server=utf8_unicode_ci
init_connect='SET NAMES utf8'
server_id=202                    #这里的ID号与从库上或者主库上的ID必须保证不唯一
log-bin=mysql-bin                    #可以自定义 这里定义为 log-bin=/data/log-bin/log-bin-3310
binlog_format=row                    #主从复制模式
log-slave-updates=true                 #slave 更新是否记入日志
gtid-mode=on                                   # 启用gtid类型，否则就是普通的复制架构
enforce-gtid-consistency=true          #强制GTID 的一致性 
master-info-repository=TABLE        #主服信息记录库=表 /文件
relay-log-info-repository=TABLE    #中继日志信息记录库
sync-master-info=1                         #同步主库信息
slave-parallel-workers=13                 #从服务器的SQL 线程数，要复制库数目相同
binlog-checksum=CRC32                   # 校验码 ，可以自定义
master-verify-checksum=1               #主服校验
slave-sql-verify-checksum=1             #从服校验
binlog-rows-query-log_events=1     #二进制日志详细记录事件
report-port=3306                            #提供复制报告端口，当前实例端口号
report-host=192.168.1.46               #提供复制报告主机，本机的ip地址
replicate-wild-ignore-table=mysql.%
replicate-wild-ignore-table=information_schema.%
replicate-wild-ignore-table=sys.%
replicate-wild-ignore-table=performance_schema.%
replicate-wild-ignore-table=turingcloudx_config.%
replicate-wild-ignore-table=turingcloudx.sys_tenant
replicate-wild-ignore-table=turingcloudx_device.device_message_point_data
[client]
default-character-set=utf8
[mysql]
default-character-set=utf8
eof
```


```
grant replication slave,replication client on *.* to slave@'%'identified by 'Iot@123456';
flush privileges;
```
```
change master to master_host='192.168.1.46',master_port=3306,master_user='slave',master_password='Iot@123456',master_auto_position=1;
slave start;
show slave status;
```
```
mysqldump -hhost -uroot -ppassword --single-transaction --all-databases > `date +%F`backup.sql
```
```
mysqldump -h139.198.123.207 -P33306 -uroot -p --single-transaction --master-data=0 --set-gtid-purged=OFF --hex-blob --triggers --routines --events --all-databases > `date +%F`backup.sql
```
### 不建议设置支持跳过
```
set global slave_exec_mode=IDEMPOTENT;
```
### 通过show slave status 
查看到错误的表的信息，在解决数据一致性问题。
```
select *  from performance_schema.replication_applier_status_by_worker;

```
### 需要同步之前数据库一致
```
FLUSH TABLES WITH READ LOCK ;
UNLOCK TABLES ;
reset MASTER;
```

### 主从复制处理删除不存在的错误
```
show slave STATUS;

SELECT * FROM performance_schema.replication_applier_status_by_worker;

stop slave;set global sql_slave_skip_counter=1;start slave;

show master logs

show slave status ;
STOP SLAVE;
SET @@SESSION.GTID_NEXT='c0472aef-a3a5-11ed-9eaf-22b1696e778a:251669';
BEGIN; COMMIT;
SET SESSION GTID_NEXT = AUTOMATIC;
START SLAVE;

```


```
mysql -u root -p 
use mysql
select `user`,authentication_string,`Host` from `user`;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY 'Iot@123456';
flush privileges;