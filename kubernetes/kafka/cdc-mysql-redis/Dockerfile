# Kafka Connect CDC 镜像 — 带 Debezium MySQL + Redis Sink
# 用法: docker build -t <IMAGE_TAG> -f Dockerfile .
#
# 插件从 Nexus 下载(公网直连不稳),也可以改 URL 直接用上游地址:
#   Debezium MySQL : https://repo1.maven.org/maven2/io/debezium/debezium-connector-mysql/3.5.2.Final/debezium-connector-mysql-3.5.2.Final-plugin.tar.gz
#   Redis          : https://github.com/redis-field-engineering/redis-kafka-connect/releases/download/v1.1.0/redis-redis-kafka-connect-1.1.0.zip

# 基础镜像必须用 Strimzi,不要用 confluentinc/cp-kafka-connect
# tag 用运行中 broker 的镜像最稳:
#   kubectl -n kafka get pod kafka-cluster-kafka-0 -o jsonpath='{.spec.containers[0].image}'
ARG BASE_IMAGE=quay.io/strimzi/kafka:1.0.1-kafka-4.2.0
FROM ${BASE_IMAGE}

# === 版本 ===
ARG DEBEZIUM_VERSION=3.5.2.Final
ARG REDIS_VERSION=1.1.0
ARG NEXUS_BASE=https://nexus.ihome.sxxpqp.top:8443/repository/raw-hosted/kafka-connect

# === 下载插件 ===
# Strimzi 镜像没有包管理器,只能用已有工具:
#   tar 解压 .tar.gz, jar(Java 内置) 解压 .zip
RUN curl -fLo /tmp/debezium-plugin.tar.gz "${NEXUS_BASE}/debezium-connector-mysql-${DEBEZIUM_VERSION}-plugin.tar.gz" \
 && mkdir -p /opt/kafka/plugins/debezium-connector-mysql \
 && tar xzf /tmp/debezium-plugin.tar.gz -C /opt/kafka/plugins/debezium-connector-mysql --strip-components=1 \
 && rm -f /tmp/debezium-plugin.tar.gz \
 && curl -fLo /tmp/redis-plugin.zip "${NEXUS_BASE}/redis-redis-kafka-connect-${REDIS_VERSION}.zip" \
 && mkdir -p /opt/kafka/plugins/redis-kafka-connect \
 && cd /opt/kafka/plugins/redis-kafka-connect \
 && jar xf /tmp/redis-plugin.zip \
 && mv /opt/kafka/plugins/redis-kafka-connect/redis-redis-kafka-connect-${REDIS_VERSION}/lib/* \
    /opt/kafka/plugins/redis-kafka-connect/ 2>/dev/null || true \
 && rm -rf /opt/kafka/plugins/redis-kafka-connect/redis-redis-kafka-connect-${REDIS_VERSION} \
 && rm -f /tmp/redis-plugin.zip

# Strimzi 镜像默认用非 root 用户,上面 curl 已用 root 跑完,切回原用户
USER 1001
