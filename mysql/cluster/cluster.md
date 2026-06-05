# MySQL Group Replication (MGR) 三节点单主部署

> 源: https://github.com/sxxpqp/linux/blob/main/mysql/cluster/cluster.md
> 状态: 验证过

从 0 到可用的完整部署过程,一步不省。

## 目标

| 项 | 值 |
|---|---|
| MySQL 版本 | 8.0 |
| 拓扑 | 3 节点 Group Replication,单主模式 |
| Router | MySQL Router 与 MySQL 同机部署(Sidecar) |
| 节点 | `192.168.100.24` / `25` / `26`(主机名 `mysql24` / `25` / `26`) |
| 接入 | 应用通过 Router 访问数据库(自动主备切换) |

> 👉 这是生产可用的官方方案。

---

## 一、基础环境准备(3 台都执行)

### 1. 设置主机名

```bash
hostnamectl set-hostname mysql24   # 24
hostnamectl set-hostname mysql25   # 25
hostnamectl set-hostname mysql26   # 26
```

`/etc/hosts`:

```
192.168.100.24 mysql24
192.168.100.25 mysql25
192.168.100.26 mysql26
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

# 2. 安装 MySQL Server
yum install -y mysql-community-server

# 3. 启动
systemctl enable mysqld --now

# 4. 取初始密码 + 安全初始化
grep 'temporary password' /var/log/mysqld.log
mysql_secure_installation
```

---

## 三、MySQL 核心配置(MGR 关键)

3 台都要配,**只有 `server-id` 和 `local_address` 不同**。

编辑 `/etc/my.cnf`,公共部分:

```ini
[mysqld]
bind-address=0.0.0.0
gtid_mode=ON
enforce_gtid_consistency=ON
log_bin=mysql-bin
binlog_format=ROW
log_slave_updates=ON
transaction_write_set_extraction=XXHASH64
loose-group_replication_group_name="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
loose-group_replication_start_on_boot=OFF
loose-group_replication_group_seeds="192.168.100.24:33061,192.168.100.25:33061,192.168.100.26:33061"
loose-group_replication_bootstrap_group=OFF
loose-group_replication_single_primary_mode=ON
loose-group_replication_enforce_update_everywhere_checks=OFF
```

每台节点独立配置:

```ini
# 192.168.100.24
server-id=1
loose-group_replication_local_address="192.168.100.24:33061"

# 192.168.100.25
server-id=2
loose-group_replication_local_address="192.168.100.25:33061"

# 192.168.100.26
server-id=3
loose-group_replication_local_address="192.168.100.26:33061"
```

重启 MySQL:

```bash
systemctl restart mysqld
```

---

## 四、创建复制用户(3 台都执行)

```sql
CREATE USER 'repl'@'%' IDENTIFIED BY 'Repl@123';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;
```

## 五、启用 Group Replication 插件(3 台)

```sql
INSTALL PLUGIN group_replication SONAME 'group_replication.so';
```

## 六、配置恢复通道(3 台)

```sql
CHANGE MASTER TO
  MASTER_USER='repl',
  MASTER_PASSWORD='Repl@123'
  FOR CHANNEL 'group_replication_recovery';
```

---

## 七、启动 MGR 集群(顺序非常重要)

### 1. 在 `192.168.100.24`(第一个节点)— 引导

```sql
SET GLOBAL group_replication_bootstrap_group=ON;
START GROUP_REPLICATION;
SET GLOBAL group_replication_bootstrap_group=OFF;
```

### 2. 在 `192.168.100.25`

```sql
START GROUP_REPLICATION;
```

### 3. 在 `192.168.100.26`

```sql
START GROUP_REPLICATION;
```

### 4. 验证

```sql
SELECT MEMBER_HOST, MEMBER_STATE
FROM performance_schema.replication_group_members;
```

期望:3 个节点全部 `ONLINE`。

---

## 八、安装 MySQL Router(3 台都执行)

```bash
yum install -y mysql-router
```

## 九、创建 Router 管理用户(只在 Primary)

```sql
CREATE USER 'router'@'%' IDENTIFIED BY 'Router@123';
GRANT ALL PRIVILEGES ON *.* TO 'router'@'%';
FLUSH PRIVILEGES;
```

## 十、初始化 MySQL Router(3 台都执行)

> ⚠ bootstrap 可连任意 MySQL 节点。

```bash
# 在 192.168.100.24
mysqlrouter \
  --bootstrap router@192.168.100.24:3306 \
  --directory /etc/mysqlrouter \
  --user mysqlrouter \
  --force

# 在 192.168.100.25
mysqlrouter \
  --bootstrap router@192.168.100.25:3306 \
  --directory /etc/mysqlrouter \
  --user mysqlrouter \
  --force

# 在 192.168.100.26
mysqlrouter \
  --bootstrap router@192.168.100.26:3306 \
  --directory /etc/mysqlrouter \
  --user mysqlrouter \
  --force
```

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

应用配多个 Router IP,任意一个挂了换下一个:

```
192.168.100.24:6446, 192.168.100.25:6446, 192.168.100.26:6446
```

JDBC 示例:

```
jdbc:mysql://192.168.100.24:6446,192.168.100.25:6446,192.168.100.26:6446/appdb
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
