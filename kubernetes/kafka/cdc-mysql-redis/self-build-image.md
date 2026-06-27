# Kafka Connect CDC 镜像自打包部署(备选方案)

> 状态: 学习笔记 / 模板
> 目标:自己 `docker build` 一个带 **Debezium MySQL Source** + **Redis Sink** 的 Kafka Connect 镜像,推私有仓库后在 Strimzi 部署,实现 MySQL → Kafka → Redis 实时同步。
> 关系:这是 [kafka-connect.yaml](kafka-connect.yaml)(Strimzi `build` 自动构建)的**手动替代版**。两种二选一,见文末对比。

## ⚠ 跟"网上常见写法"的两个关键区别(否则跑不起来/结果不对)

1. **基础镜像必须 `FROM` Strimzi 的 kafka 镜像,不是 `confluentinc/cp-kafka-connect`**。Strimzi 的 KafkaConnect 用自己的入口脚本/配置/探针(`/opt/kafka/...`),套 Confluent 镜像会起不来。所以也**不用 `confluent-hub`**,直接把插件 COPY 进 `/opt/kafka/plugins/`。
2. **连接器必须带 `unwrap`(ExtractNewRecordState)+ key 提取**,否则 Redis 存的是整个 Debezium 信封(`before/after/op/...`)而不是表的行,"整行镜像"做不出来。

## 一、整体链路

```
MySQL ──(Debezium 读 binlog)──> Kafka ──(Redis Sink)──> Redis
                                                   每行一个 HASH key,删除→DEL
```

版本对齐 Kafka **4.2.0**(集群版本):

| 组件 | 版本 | 说明 |
|---|---|---|
| 基础镜像 | `quay.io/strimzi/kafka:1.0.1-kafka-4.2.0` | Strimzi operator 1.0.1 + Kafka 4.2.0 |
| Debezium MySQL | **3.5.2.Final** | 基于 kafka-clients 4.1.2,对 4.2 集群 4.x 内兼容 |
| Redis Kafka Connect | **1.1.0** | redis-field-engineering 最新 release |

> 基础镜像 tag 以集群实际为准,直接抄运行中 broker 的镜像最稳:
> ```bash
> kubectl -n kafka get pod kafka-cluster-kafka-0 \
>   -o jsonpath='{.spec.containers[0].image}'; echo
> ```

## 二、准备插件 + 写 Dockerfile

新建目录,先把两个插件下下来并解压(走 Nexus,公网直连不稳;上游地址见 [README.md](README.md) 前置 2):

```bash
mkdir -p plugins && cd plugins
# Debezium MySQL 3.5.2.Final
curl -fLO https://nexus.ihome.sxxpqp.top:8443/repository/raw-hosted/kafka-connect/debezium-connector-mysql-3.5.2.Final-plugin.tar.gz
mkdir -p debezium-connector-mysql && tar xzf debezium-connector-mysql-3.5.2.Final-plugin.tar.gz -C debezium-connector-mysql --strip-components=1
# Redis Kafka Connect 1.1.0
curl -fLO https://nexus.ihome.sxxpqp.top:8443/repository/raw-hosted/kafka-connect/redis-redis-kafka-connect-1.1.0.zip
unzip -q redis-redis-kafka-connect-1.1.0.zip
cd ..
```

`Dockerfile`:

```dockerfile
FROM quay.io/strimzi/kafka:1.0.1-kafka-4.2.0
USER root:root
# 插件丢进 Strimzi 约定目录 /opt/kafka/plugins/,每个连接器一个子目录
COPY ./plugins/debezium-connector-mysql/            /opt/kafka/plugins/debezium-connector-mysql/
COPY ./plugins/redis-redis-kafka-connect-1.1.0/lib/ /opt/kafka/plugins/redis-kafka-connect/
USER 1001
```

> 路径以解压后的实际结构为准(redis zip 解出来一般是 `redis-redis-kafka-connect-1.1.0/lib/*.jar`)。

## 三、构建并推送镜像

私有仓库以 `hub.wishfoxs.com:6443` 为例:

```bash
# 构建机 docker 需能拉 quay.io/strimzi(走 mirror 或直连)
docker build -t hub.wishfoxs.com:6443/pre/kafka-connect-cdc:v1.0.0 .
docker login hub.wishfoxs.com:6443
docker push  hub.wishfoxs.com:6443/pre/kafka-connect-cdc:v1.0.0
```

> 私有仓库自签证书:构建机 docker **和 k8s 各节点 containerd** 都要信任该证书,否则推/拉失败。若仓库要登录,k8s 侧还要建 `imagePullSecret` 并在 KafkaConnect 里引用。

## 四、部署 KafkaConnect(用自打镜像,无 `build` 字段)

`kafka-connect.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnect
metadata:
  name: cdc-connect
  namespace: kafka
  annotations:
    strimzi.io/use-connector-resources: "true"
spec:
  version: 4.2.0                                              # 跟集群对齐,不是 3.6.0
  replicas: 1
  image: hub.wishfoxs.com:6443/pre/kafka-connect-cdc:v1.0.0   # 自打镜像
  bootstrapServers: kafka-cluster-kafka-bootstrap:9092
  config:
    group.id: cdc-connect
    offset.storage.topic: cdc-connect-offsets
    config.storage.topic: cdc-connect-configs
    status.storage.topic: cdc-connect-status
    config.storage.replication.factor: 3
    offset.storage.replication.factor: 3
    status.storage.replication.factor: 3
    key.converter: org.apache.kafka.connect.json.JsonConverter
    value.converter: org.apache.kafka.connect.json.JsonConverter
    key.converter.schemas.enable: false
    value.converter.schemas.enable: false
    # 从 Secret 注入连接器密码
    config.providers: secrets
    config.providers.secrets.class: io.strimzi.kafka.KubernetesSecretConfigProvider
  template:
    pod:
      nodeSelector:
        kafka: "true"
```

> 自打镜像也要让 Connect SA 能读 Secret:RBAC 跟 [kafka-connect.yaml](kafka-connect.yaml) 里那段 Role/RoleBinding 一样,一起 apply。

```bash
kubectl apply -f kafka-connect.yaml
kubectl -n kafka get kafkaconnect cdc-connect -w     # READY=True
```

## 五、连接器(KafkaConnector)

连接器配置跟 Strimzi build 方案**完全一样**,直接用 [connectors.yaml](connectors.yaml)(`strimzi.io/cluster` 已是 `cdc-connect`)。关键是两个 transform 别漏:

**Source(Debezium)** —— 必带 `unwrap`:

```yaml
    transforms: unwrap
    transforms.unwrap.type: io.debezium.transforms.ExtractNewRecordState
    transforms.unwrap.delete.tombstone.handling.mode: tombstone   # 删除→tombstone→Redis DEL
```

**Sink(Redis)** —— 必带 key 提取 + HASH:

```yaml
    redis.type: HASH
    redis.keyspace: ${topic}          # key = mysqlcdc.app_db.users:<id>
    redis.separator: ":"
    transforms: extractKey
    transforms.extractKey.type: org.apache.kafka.connect.transforms.ExtractField$Key
    transforms.extractKey.field: id   # 单列主键
```

```bash
kubectl apply -f connectors.yaml
kubectl -n kafka get kafkaconnector
```

## 六、验证

```bash
# 插件已装(应看到 MySqlConnector + RedisSinkConnector)
kubectl -n kafka exec deploy/cdc-connect-connect -- \
  curl -s localhost:8083/connector-plugins | jq '.[].class'

# 连接器状态(RUNNING)
kubectl -n kafka exec deploy/cdc-connect-connect -- \
  curl -s localhost:8083/connectors/mysql-source/status | jq .connector.state

# 改一条 MySQL 数据 → 看 Redis(key 形如 mysqlcdc.app_db.users:1)
redis-cli -h <REDIS_HOST> -a <REDIS_PASSWORD> HGETALL mysqlcdc.app_db.users:1
```

## 七、注意事项

1. **MySQL 前置**:`binlog_format=ROW` + `binlog_row_image=FULL`;CDC 账号需 `REPLICATION SLAVE` / `REPLICATION CLIENT` / `SELECT`。详见 [README.md](README.md) 前置 1。
2. **`database.server.id` 唯一**:整个复制拓扑里不能和 MySQL 实例或其它 CDC 任务重复。
3. **版本对齐 4.2**:基础镜像 / Debezium / Redis connector 都按上面表,别用 latest 或老的 cp-kafka-connect。
4. **私有仓库证书 + 拉取凭据**:节点信任自签证书;要登录则配 `imagePullSecret`。
5. **⚠ 磁盘 IO 前置**:Debezium 持续读 binlog 会增加读 IO。当前 MySQL 实例磁盘 IO 偏慢,**建议先治理 IO**(放宽刷盘参数 / 调大 `innodb_buffer_pool_size` / 评估换 SSD)再上 CDC,避免加重库负担。

## 八、自打镜像 vs Strimzi build 怎么选

| | 自打镜像(本文) | Strimzi `build`([kafka-connect.yaml](kafka-connect.yaml)) |
|---|---|---|
| 谁构建镜像 | 你手动 `docker build/push` | operator 自动建 + 推 ACR |
| 改插件 | 重新 build/push 镜像 | 改 yaml `artifacts` 重 apply |
| 适合 | CI 流水线已成型 / 想自己掌控镜像 / 离线 | **默认推荐,省事** |

> 两者产出的运行效果一致(都是 Strimzi 基础镜像 + 同版本插件 + 同连接器配置)。

## 九、变更记录

| 版本 | 说明 |
|------|------|
| v1.0.0 | Strimzi 基础镜像(1.0.1-kafka-4.2.0)+ Debezium 3.5.2.Final + Redis Kafka Connect 1.1.0;补 unwrap + key 提取 |
