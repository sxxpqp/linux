# MySQL → Kafka → Redis 实时同步(Debezium CDC,整行镜像做缓存)

> 状态: 学习笔记 / 模板(未在集群跑全流程,占位符需按环境填)
> 前置:[Kafka 集群已部署](../operator/)(`kafka-cluster-kafka-bootstrap:9092` 可达)

## 架构

```
MySQL(binlog)                Kafka                         Redis
   │                          │                             │
   ▼                          ▼                             ▼
Debezium MySQL Source ──► topic mysqlcdc.app_db.users ──► Redis Sink
  读 binlog,ExtractNewRecordState        每表一个 topic       每行一个 HASH key
  拆信封→只留 after 行                                        删除→DEL key(缓存失效)
```

- **整行镜像**:MySQL 一行 = Redis 一个 key(`mysqlcdc.app_db.users:<id>`),`redis.type=HASH` 每列一个 field
- **删除传播**:MySQL 删行 → Debezium tombstone(null 值)→ Redis Sink **DEL key**,缓存自动失效
- **可回放**:数据落在 Kafka,Redis 挂了重建只要重置 sink offset 重放

## 文件

| 文件 | 内容 |
|---|---|
| [kafka-connect.yaml](kafka-connect.yaml) | KafkaConnect 集群(operator 构建镜像,内置 Debezium + Redis 插件)+ 读 Secret 的 RBAC |
| [connectors.yaml](connectors.yaml) | Secret + Debezium 源连接器 + Redis 汇连接器 |

## 要先填的占位符

| 占位符 | 在哪 | 填什么 |
|---|---|---|
| `<MYSQL_HOST>` | connectors.yaml | MySQL 地址(集群内 svc 或外部 IP) |
| `<REDIS_HOST>` | connectors.yaml | Redis 地址 |
| `app_db` / `app_db.users` | connectors.yaml | 实际库名 / 表名 |
| `id` | connectors.yaml(extractKey.field) | 表的主键列名 |
| `<MYSQL_DEBEZIUM_PASSWORD>` / `<REDIS_PASSWORD>` | connectors.yaml Secret | 密码 |
| `registry.cn-hangzhou.aliyuncs.com/sxxpqp/...` | kafka-connect.yaml | 构建镜像推送目标(ACR) |

## 前置 1:MySQL 开 binlog + 建 Debezium 账号

```ini
# my.cnf [mysqld] —— 改完重启 MySQL
server-id          = 223344
log_bin            = mysql-bin
binlog_format      = ROW          # Debezium 必须 ROW
binlog_row_image   = FULL         # 整行镜像必须 FULL,否则 after 缺列
expire_logs_days   = 7
```

```sql
CREATE USER 'debezium'@'%' IDENTIFIED BY '<MYSQL_DEBEZIUM_PASSWORD>';
GRANT SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT, LOCK TABLES
  ON *.* TO 'debezium'@'%';
FLUSH PRIVILEGES;
```

> `RELOAD`/`LOCK TABLES` 给首次快照用;只想跳过锁表用 `snapshot.locking.mode=none`。

## 前置 2:把两个插件包传到 Nexus(公网直连不稳)

```bash
# 1) 下载上游(在能联网的机器)
curl -fLO https://github.com/redis-field-engineering/redis-kafka-connect/releases/download/v1.1.0/redis-redis-kafka-connect-1.1.0.zip
# Debezium MySQL 选跟你 Kafka/Connect 兼容的版本(Kafka 4.x → Debezium 3.x),示例:
curl -fLO https://repo1.maven.org/maven2/io/debezium/debezium-connector-mysql/<ver>/debezium-connector-mysql-<ver>-plugin.tar.gz

# 2) 传 Nexus raw-hosted(路径要跟 kafka-connect.yaml 的 url 对上)
curl -u <user>:<pwd> --upload-file redis-redis-kafka-connect-1.1.0.zip \
  https://nexus.ihome.sxxpqp.top:8443/repository/raw-hosted/kafka-connect/redis-redis-kafka-connect-1.1.0.zip
curl -u <user>:<pwd> --upload-file debezium-connector-mysql-<ver>-plugin.tar.gz \
  https://nexus.ihome.sxxpqp.top:8443/repository/raw-hosted/kafka-connect/debezium-connector-mysql-plugin.tar.gz
```

## 前置 3:建 ACR 推送 secret(给 operator 构建后推镜像)

```bash
kubectl -n kafka create secret docker-registry acr-push-secret \
  --docker-server=registry.cn-hangzhou.aliyuncs.com \
  --docker-username=<ACR用户> --docker-password=<ACR密码>
```

## 部署顺序

```bash
# 1. 起 Connect 集群(operator 会先 build 镜像→推 ACR→再拉起,首次几分钟)
kubectl apply -f kafka-connect.yaml
kubectl -n kafka get kafkaconnect cdc-connect -w     # READY=True

# 2. 建连接器(先填好 connectors.yaml 占位符)
kubectl apply -f connectors.yaml

# 3. 看连接器状态
kubectl -n kafka get kafkaconnector
# mysql-source / redis-sink 的 READY 都要 True
```

## 验证

```bash
# topic 出来了(每个表一个)
kubectl -n kafka run kcat --rm -it --image=edenhill/kcat:1.7.1 --restart=Never -- \
  -b kafka-cluster-kafka-bootstrap:9092 -L | grep mysqlcdc

# topic 里有数据(改一行 MySQL 再看)
kubectl -n kafka run kcat --rm -it --image=edenhill/kcat:1.7.1 --restart=Never -- \
  -b kafka-cluster-kafka-bootstrap:9092 -C -t mysqlcdc.app_db.users -o -5 -e

# Redis 里落到了(<id> 换真实主键值)
redis-cli -h <REDIS_HOST> -a <REDIS_PASSWORD> HGETALL mysqlcdc.app_db.users:1
# 删一行 MySQL,确认 key 消失:
redis-cli -h <REDIS_HOST> -a <REDIS_PASSWORD> EXISTS mysqlcdc.app_db.users:1   # → 0
```

## 踩坑

| # | 现象 / 风险 | 原因 | 修法 |
|---|---|---|---|
| 1 | 删除不生效 / 连接器报未知配置 | `ExtractNewRecordState` 删除处理项**版本间改过名** | Debezium 2.0-2.3:`delete.handling.mode=none` + `drop.tombstones=false`(本模板默认);**2.4+/3.x 改成** `delete.tombstone.handling.mode=tombstone`。按你装的版本二选一 |
| 2 | 组合主键写进 Redis key 变怪 | `ExtractField$Key` 只能取**单列** | 组合主键改用 `transforms.extractKey.type: ...HoistField` 或自定义 SMT 拼 key;或 sink 用 `redis.keyspace` 模板 |
| 3 | Connect 起不来,卡 build | ACR push secret 缺 / Nexus 包路径不对 | `kubectl -n kafka describe kafkaconnect cdc-connect` 看 build Pod 日志;核对前置 2/3 |
| 4 | 连接器 `RUNNING` 但 Redis 没数据 | 两端 converter 不一致 / key 没拆成标量 | 确认 KafkaConnect `config` 里 schemas.enable=false 两端统一;`kubectl -n kafka logs deploy/cdc-connect-connect` |
| 5 | `${secrets:...}` 没解析,密码原样 | config provider 类名 / RBAC 不对 | 核对 `io.strimzi.kafka.KubernetesSecretConfigProvider` 在你的 Strimzi build 里存在 + RBAC Role 已 apply |
| 6 | HASH 存不下嵌套/JSON 列 | HASH 字段只能是扁平标量 | 含 JSON 列的表改 `redis.type=STRING`(整行存 JSON 字符串),应用侧自己解析 |
| 7 | server.id 冲突,binlog 读不到 | 多个 Debezium / 真 replica 用了同一 `database.server.id` | 每个连接器给唯一值 |

## HASH vs STRING 怎么选

| | `redis.type=HASH`(默认) | `redis.type=STRING` |
|---|---|---|
| Redis 形态 | 每列一个 field,`HGETALL` 读 | 整行一个 JSON 字符串,`GET` 读 |
| 读单字段 | `HGET key col` 省带宽 | 取整串再解析 |
| 含 JSON/嵌套列 | ❌ 字段必须扁平 | ✅ 原样存 |
| 应用改动 | 按 hash 读 | 按 JSON 解析 |

> 纯缓存整行、字段都是标量 → **HASH**;表里有 JSON 列或想直接缓存整个对象 → **STRING**。
