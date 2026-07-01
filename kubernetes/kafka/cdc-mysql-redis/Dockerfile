# Kafka Connect CDC 镜像 — 带 Debezium MySQL + Redis Sink
# 用法: 先下载插件到 ./plugins/, 再 docker build
#
# 插件下载地址(构建机公网直连,或手动上传到 chfs):
#   Debezium MySQL : https://repo1.maven.org/maven2/io/debezium/debezium-connector-mysql/3.5.2.Final/debezium-connector-mysql-3.5.2.Final-plugin.tar.gz
#   Redis          : https://github.com/redis-field-engineering/redis-kafka-connect/releases/download/v1.1.0/redis-redis-kafka-connect-1.1.0.zip

# 基础镜像必须用 Strimzi,不要用 confluentinc/cp-kafka-connect
# tag 用运行中 broker 的镜像最稳:
#   kubectl -n kafka get pod kafka-cluster-kafka-0 -o jsonpath='{.spec.containers[0].image}'
ARG BASE_IMAGE=quay.io/strimzi/kafka:1.0.1-kafka-4.2.0
FROM ${BASE_IMAGE}

# 构建时 COPY 本地插件目录,不依赖构建机网络
# 插件需提前准备好:
#   plugins/
#   ├── debezium-connector-mysql/          # tar xzf 解压后的目录
#   └── redis-kafka-connect/               # jar 解压后的 lib/*.jar
COPY plugins/debezium-connector-mysql/ /opt/kafka/plugins/debezium-connector-mysql/
COPY plugins/redis-kafka-connect/      /opt/kafka/plugins/redis-kafka-connect/

# Strimzi 镜像默认用非 root 用户
USER 1001
