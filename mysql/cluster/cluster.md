# MySQL Group Replication (MGR) 三节点单主部署

> 源: https://github.com/sxxpqp/linux/blob/main/mysql/cluster/cluster.md
> 状态: 验证过
> 方式: mysqlsh（推荐）

从 0 到可用的完整部署过程,一步不省。

## 目标

| 项 | 值 |
|---|---|
| MySQL 版本 | 8.0 |
| 拓扑 | 3 节点 Group Replication,单主模式 |
| Router | MySQL Router 与 MySQL 同机部署(Sidecar) |
| 节点 | `db1(172.16.0.134)` / `db2(172.16.0.69)` / `db3(172.16.0.70)` |
| 接入 | 应用通过 Router 访问数据库(自动主备切换) |

> 👉 这是生产可用的官方方案。

---

## 一、基础环境准备(3 台都执行)

### 1. 设置主机名

```bash
hostnamectl set-hostname db1   # db1 上
hostnamectl set-hostname db2   # db2 上
hostnamectl set-hostname db3   # db3 上
```

`/etc/hosts`(3 台都加):

```
172.16.0.134 db1
172.16.0.69 db2
172.16.0.70 db3
```

### 2. 关闭防火墙和 SELinux

```bash
systemctl stop firewalld
systemctl disable firewalld
setenforce 0
```

### 3. 时间同步(必须)

```bash
yum install -y chrony
systemctl enable chronyd --now
```

---

## 二、安装 MySQL 8.0(3 台都执行)

```bash
# 1. 安装官方源
rpm -Uvh https://repo.mysql.com/mysql80-community-release-el7-7.noarch.rpm
rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023

# 2. 安装 MySQL Server + Shell + Router
yum install -y mysql-community-server-8.0.44 mysql-shell mysql-router

# 3. 启动
systemctl enable mysqld --now

# 4. 取初始密码 + 安全初始化
grep 'temporary password' /var/log/mysqld.log
mysql_secure_installation
```

---

## 三、MySQL 核心配置(MGR 关键)

每台节点完整 `my.cnf`（只有 `server-id` 和 `local_address` 不同）：

### db1 — /etc/my.cnf

```ini
[mysqld]
server-id=1
bind-address=0.0.0.0
sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
wait_timeout=600
default-time-zone='Asia/Shanghai'
interactive_timeout=600
max_allowed_packet=1G
net_read_timeout=600
net_write_timeout=600
max_connections=2000
innodb_buffer_pool_size=8G
innodb_buffer_pool_instances=4
slow_query_log=1
slow_query_log_file=/var/lib/mysql/mysql-slow.log
long_query_time=1
log_output=FILE

# MGR 必须参数
gtid_mode=ON
enforce_gtid_consistency=ON
log_bin=mysql-bin
binlog_format=ROW
log_slave_updates=ON
transaction_write_set_extraction=XXHASH64
binlog_transaction_dependency_tracking=WRITESET
loose-group_replication_group_name="8a8f8f8f-1234-5678-9abc-def0abcdef01"
loose-group_replication_start_on_boot=OFF
loose-group_replication_group_seeds="db1:33061,db2:33061,db3:33061"
loose-group_replication_bootstrap_group=OFF
loose-group_replication_single_primary_mode=ON
loose-group_replication_enforce_update_everywhere_checks=OFF
loose-group_replication_local_address="db1:33061"

datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock
log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid
```

### db2 — /etc/my.cnf

```ini
[mysqld]
server-id=2
bind-address=0.0.0.0
sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
wait_timeout=600
default-time-zone='Asia/Shanghai'
interactive_timeout=600
max_allowed_packet=1G
net_read_timeout=600
net_write_timeout=600
max_connections=2000
innodb_buffer_pool_size=8G
innodb_buffer_pool_instances=4
slow_query_log=1
slow_query_log_file=/var/lib/mysql/mysql-slow.log
long_query_time=1
log_output=FILE

# MGR 必须参数
gtid_mode=ON
enforce_gtid_consistency=ON
log_bin=mysql-bin
binlog_format=ROW
log_slave_updates=ON
transaction_write_set_extraction=XXHASH64
binlog_transaction_dependency_tracking=WRITESET
loose-group_replication_group_name="8a8f8f8f-1234-5678-9abc-def0abcdef01"
loose-group_replication_start_on_boot=OFF
loose-group_replication_group_seeds="db1:33061,db2:33061,db3:33061"
loose-group_replication_bootstrap_group=OFF
loose-group_replication_single_primary_mode=ON
loose-group_replication_enforce_update_everywhere_checks=OFF
loose-group_replication_local_address="db2:33061"

datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock
log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid
```

### db3 — /etc/my.cnf

```ini
[mysqld]
server-id=3
bind-address=0.0.0.0
sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
wait_timeout=600
default-time-zone='Asia/Shanghai'
interactive_timeout=600
max_allowed_packet=1G
net_read_timeout=600
net_write_timeout=600
max_connections=2000
innodb_buffer_pool_size=8G
innodb_buffer_pool_instances=4
slow_query_log=1
slow_query_log_file=/var/lib/mysql/mysql-slow.log
long_query_time=1
log_output=FILE

# MGR 必须参数
gtid_mode=ON
enforce_gtid_consistency=ON
log_bin=mysql-bin
binlog_format=ROW
log_slave_updates=ON
transaction_write_set_extraction=XXHASH64
binlog_transaction_dependency_tracking=WRITESET
loose-group_replication_group_name="8a8f8f8f-1234-5678-9abc-def0abcdef01"
loose-group_replication_start_on_boot=OFF
loose-group_replication_group_seeds="db1:33061,db2:33061,db3:33061"
loose-group_replication_bootstrap_group=OFF
loose-group_replication_single_primary_mode=ON
loose-group_replication_enforce_update_everywhere_checks=OFF
loose-group_replication_local_address="db3:33061"

datadir=/var/lib/mysql
socket=/var/lib/mysql/mysql.sock
log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid
```

重启 MySQL:

```bash
systemctl restart mysqld
```

---

## 四、统一 root 密码(3 台都执行)

> ⚠️ 如果节点是从同一镜像克隆的,每台密码必须单独设置,否则后续 addInstance 会报 Authentication error。

```sql
-- 所有节点都执行
ALTER USER 'root'@'localhost' IDENTIFIED BY 'YourStrong@Pass123';
CREATE USER 'root'@'%' IDENTIFIED BY 'YourStrong@Pass123';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;


# 前面添加了 
-- db1 额外执行(db1 作为集群引导节点,MySQL Shell dba 函数需要 root@db1)
CREATE USER 'root'@'db1' IDENTIFIED BY 'YourStrong@Pass123';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'db1' WITH GRANT OPTION;
GRANT SELECT ON mysql_innodb_cluster_metadata.* TO 'root'@'db1';
FLUSH PRIVILEGES;
```

验证三台都能用密码登录:

```bash
mysql -uroot -p'YourStrong@Pass123' -h db1 -e "SELECT 1"
mysql -uroot -p'YourStrong@Pass123' -h db2 -e "SELECT 1"
mysql -uroot -p'YourStrong@Pass123' -h db3 -e "SELECT 1"
```

---

## 五、引导并创建集群(只在 db1 执行)

```bash
mysqlsh root@db1 -p
```

```javascript
var cluster = dba.createCluster('testCluster', {
  multiPrimary: false
});
cluster.addInstance('root@db2:3306', { password: 'YourStrong@Pass123' });
cluster.addInstance('root@db3:3306', { password: 'YourStrong@Pass123' });
```

> 如果节点是从镜像克隆的,第一次 addInstance 会报 GTID errant,选 **C** (Clone) 即可,会自动用集群数据覆盖新节点。

---

## 六、验证集群状态

```javascript
var cluster = dba.getCluster('testCluster');
cluster.status();
```

期望输出:

```
"status": "OK",
"topology": {
    "db1:3306": { "status": "ONLINE", "memberRole": "PRIMARY" },
    "db2:3306": { "status": "ONLINE", "memberRole": "SECONDARY" },
    "db3:3306": { "status": "ONLINE", "memberRole": "SECONDARY" }
}
```

---

## 七、常见错误与处理

### 错误 1: server UUID 相同(克隆镜像后常见)

```
Cannot add an instance with the same server UUID
```

处理:

```bash
rm -f /data/mysql/auto.cnf
systemctl restart mysqld
```

### 错误 2: binlog_transaction_dependency_tracking 不是 WRITESET

```
binlog_transaction_dependency_tracking | COMMIT_ORDER | WRITESET
```

处理: 在 `my.cnf` 加 `binlog_transaction_dependency_tracking=WRITESET`,然后 `systemctl restart mysqld`

### 错误 3: Authentication error during connection check

说明目标节点 root 密码与本地不一致,在目标节点执行:

```sql
ALTER USER 'root'@'%' IDENTIFIED BY 'YourStrong@Pass123';
FLUSH PRIVILEGES;
```

---

## 八、安装 MySQL Router(3 台都执行)

```bash
yum install -y mysql-router
```

## 九、创建 Router 管理用户(只在 Primary)

```sql
-- 创建 router 用户(支持从任意节点 bootstrap)
DROP USER IF EXISTS 'router'@'%';
DROP USER IF EXISTS 'router'@'db1';
DROP USER IF EXISTS 'router'@'db2';
DROP USER IF EXISTS 'router'@'db3';
CREATE USER 'router'@'%' IDENTIFIED BY 'Router@123';
CREATE USER 'router'@'db1' IDENTIFIED BY 'Router@123';
CREATE USER 'router'@'db2' IDENTIFIED BY 'Router@123';
CREATE USER 'router'@'db3' IDENTIFIED BY 'Router@123';
GRANT ALL PRIVILEGES ON *.* TO 'router'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'router'@'db1' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'router'@'db2' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'router'@'db3' WITH GRANT OPTION;
FLUSH PRIVILEGES;
```

> `WITH GRANT OPTION` 是必须的，因为 Router bootstrap 过程会创建内部账户并授予权限。

## 十、初始化 MySQL Router(3 台都执行)

> ⚠️ bootstrap 可连任意 MySQL 节点。

```bash
# 在 db1
mysqlrouter \
  --bootstrap router@db1:3306 \
  --directory /etc/mysqlrouter \
  --user mysqlrouter \
  --force

# 在 db2
mysqlrouter \
  --bootstrap router@db2:3306 \
  --directory /etc/mysqlrouter \
  --user mysqlrouter \
  --force

# 在 db3
mysqlrouter \
  --bootstrap router@db3:3306 \
  --directory /etc/mysqlrouter \
  --user mysqlrouter \
  --force
```

> ⚠️ 生成的 `mysqlrouter.conf` 默认缺少连接限制，建议手动在 `[DEFAULT]` 段加：
> ```ini
> max_total_connections=4000
> max_connections=4000
> read_timeout=30
> ```
> 加完后 `systemctl restart mysqlrouter` 生效。

## 十一、启动 Router(3 台)

```bash
systemctl enable mysqlrouter --now
systemctl status mysqlrouter
```

---

## 十二、Router 端口说明(牢记)

| 端口 | 作用 |
|---|---|
| 6446 | 读写(自动指向 Primary) |
| 6447 | 只读 |
| 6448 | X 协议读写 |
| 6449 | X 协议只读 |

## 十三、验证 Router 功能

```bash
mysql -h 127.0.0.1 -P 6446 -u root -p
```

```sql
SELECT @@hostname, @@read_only;
```

- `read_only=0` → 当前是 Primary
- `read_only=1` → Router 自动转发到主库

---

## 十四、应用连接方式(生产推荐)

应用配多个 Router 地址,任意一个挂了换下一个:

```
db1:6446, db2:6446, db3:6446
```

JDBC 示例:

```
jdbc:mysql://db1:6446,db2:6446,db3:6446/appdb
```

## 十五、故障切换测试(必须做)

```bash
systemctl stop mysqld   # 停 Primary
```

期望:

- MGR 自动选主
- Router 自动感知
- 应用**无需改配置**

## 十六、生产建议

- ✅ Router 不需要 Keepalived(应用层多 IP 容灾即可)
- ✅ 应用配置多个 Router IP
- ✅ 只通过 Router 访问数据库,不直连 MySQL 节点
- ✅ 定期备份(从主节点)
- ⚠️ 从镜像克隆节点后,必须删除 `auto.cnf` 重新生成 UUID
