# MySQL 8.0.44 on CentOS 7 安装指南

> 状态: 新建
> 版本: 8.0.44

## 一、基础环境

```bash
# 关闭防火墙
systemctl stop firewalld
systemctl disable firewalld

# 关闭 SELinux
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

# 安装依赖
yum install -y yum-utils wget curl tar
```

## 二、安装 MySQL 8.0.44


### 方式 B: 官方 YUM 源

```bash
# 安装 MySQL YUM 源
rpm -Uvh https://repo.mysql.com/mysql80-community-release-el7-7.noarch.rpm

# 查看可用版本
yum list mysql-community-server --showduplicates | sort -r

# 一键安装 MySQL Server + Shell + Router
rpm --import https://repo.mysql.com/RPM-GPG-KEY-mysql-2023
yum install -y mysql-community-server-8.0.44 mysql-shell mysql-router
```

## 三、编辑 my.cnf

```bash
vim /etc/my.cnf
```

完整配置 `/etc/my.cnf`:

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

## 四、启动 MySQL

```bash
# 初始化(如果 data 目录为空)
mysqld --initialize --user=mysql

# 启动
systemctl enable mysqld --now

# 获取临时密码
grep 'temporary password' /var/log/mysqld.log
```

## 五、安全初始化

```bash
mysql_secure_installation
```

或手动:

```sql
-- 修改 root 密码
ALTER USER 'root'@'localhost' IDENTIFIED BY 'YourStrong@Pass123';

-- 创建远程用户
CREATE USER 'root'@'%' IDENTIFIED BY 'YourStrong@Pass123';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
```

## 六、验证

```bash
mysql -u root -p -e "SELECT VERSION();"
```

输出应为 `8.0.44`。

## 七、安装 MySQL Shell 和 MySQL Router(YUM 方式)

> 安装 MySQL YUM 源后可直接通过 yum 安装

```bash
# 安装 MySQL Shell(MySQL 客户端增强版,支持 JS/Python/SQL 模式)
yum install -y mysql-shell

# 安装 MySQL Router(MySQL 路由代理,支持 MGR 自动故障切换)
yum install -y mysql-router

# 验证
mysqlsh --version
mysqlrouter --version
```

## 八、配置 MGR 集群（mysqlsh 方式）

> ⚠️ 以下操作在 3 台 MySQL 节点全部完成 my.cnf 配置并启动后执行。

### 8.1 统一 root 密码（3 台都执行）

> ⚠️ 如果节点是从同一镜像克隆的，每台密码必须单独设置。

```sql
-- 所有节点都执行
ALTER USER 'root'@'localhost' IDENTIFIED BY 'YourStrong@Pass123';
CREATE USER 'root'@'%' IDENTIFIED BY 'YourStrong@Pass123';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;

-- db1 额外执行(db1 作为集群引导节点,MySQL Shell dba 函数需要 root@db1)
CREATE USER 'root'@'db1' IDENTIFIED BY 'YourStrong@Pass123';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'db1' WITH GRANT OPTION;
GRANT SELECT ON mysql_innodb_cluster_metadata.* TO 'root'@'db1';
FLUSH PRIVILEGES;
```

验证三台都能用密码登录：

```bash
mysql -uroot -p'YourStrong@Pass123' -h db1 -e "SELECT 1"
mysql -uroot -p'YourStrong@Pass123' -h db2 -e "SELECT 1"
mysql -uroot -p'YourStrong@Pass123' -h db3 -e "SELECT 1"
```

### 8.2 Bootstrap 引导集群（只在 db1 节点执行）

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

> 如果节点是从镜像克隆的，第一次 addInstance 会报 GTID errant，选 **C** (Clone) 即可。

### 8.3 验证集群状态

```bash
mysqlsh root@db1 -p
```

```javascript
var cluster = dba.getCluster('testCluster');
cluster.status();
```

期望输出 3 个节点全部 `ONLINE`。

---

## 九、MySQL Router 配置

> ⚠ MySQL Router 依赖 MySQL MGR 或 InnoDB Cluster 的元数据，不能单独使用。

### 9.1 前置条件：搭建 MGR 集群

参考 [cluster.md](../cluster.md) 搭建三节点 MGR，Router 需要连接有 `mysql_innodb_cluster_metadata` 的 MySQL 实例。

### 9.2 创建 Router 管理用户（仅 Primary 节点执行）

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

### 9.3 Bootstrap 初始化（3 台 MySQL 节点都执行）

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
> max_total_connections=2000
> read_timeout=30
> ```
> 加完后 `systemctl restart mysqlrouter` 生效。

### 9.4 启动 Router

```bash
systemctl enable mysqlrouter --now
systemctl status mysqlrouter
```

### 9.5 验证端口

```bash
netstat -tlnp | grep mysqlrouter
```

| 端口 | 作用 |
|---|---|
| 6446 | 读写（自动指向 Primary） |
| 6447 | 只读 |
| 6448 | X 协议读写 |
| 6449 | X 协议只读 |

### 9.6 连接测试

```bash
mysqlsh root@127.0.0.1:6446 -p
```

```sql
SELECT @@hostname, @@read_only;
```

- `read_only=0` → 当前是 Primary
- `read_only=1` → 自动转发到主库

### 9.7 应用连接方式（生产推荐）

应用配置多个 Router 地址，任意一台挂了换下一个：

```
db1:6446, db2:6446, db3:6446
```

JDBC 示例：

```
jdbc:mysql://db1:6446,db2:6446,db3:6446/appdb
```

## 十、后续配置(可选)

### 配置 SElinux 上下文(如开启 SELinux)

```bash
semanage fcontext -a -t mysqld_db_t "/data/mysql(/.*)?"
restorecon -Rv /data/mysql
```

### 配置firewalld(如开启)

```bash
firewall-cmd --add-port=3306/tcp --permanent
firewall-cmd --reload
```
