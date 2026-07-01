# Kafka Connect CDC 镜像 — 带 Debezium MySQL + Redis Sink
# 用法: docker build -t <IMAGE_TAG> -f Dockerfile .
#
# 插件走构建机公网直连:
#   Debezium MySQL : https://repo1.maven.org/maven2/io/debezium/debezium-connector-mysql/3.5.2.Final/debezium-connector-mysql-3.5.2.Final-plugin.tar.gz
#   Redis          : https://github.com/redis-field-engineering/redis-kafka-connect/releases/download/v1.1.0/redis-redis-kafka-connect-1.1.0.zip

# 基础镜像必须用 Strimzi,不要用 confluentinc/cp-kafka-connect
# tag 用运行中 broker 的镜像最稳:
#   kubectl -n kafka get pod kafka-cluster-kafka-0 -o jsonpath='{.spec.containers[0].image}'
ARG BASE_IMAGE=quay.io/strimzi/kafka:1.0.1-kafka-4.2.0
FROM ${BASE_IMAGE}

# Strimzi 镜像没有包管理器,只能用已有工具:
#   tar 解压 .tar.gz, jar(Java 内置) 解压 .zip
RUN curl -fLo /tmp/debezium-plugin.tar.gz \
         "https://repo1.maven.org/maven2/io/debezium/debezium-connector-mysql/3.5.2.Final/debezium-connector-mysql-3.5.2.Final-plugin.tar.gz" \
 && mkdir -p /opt/kafka/plugins/debezium-connector-mysql \
 && tar xzf /tmp/debezium-plugin.tar.gz -C /opt/kafka/plugins/debezium-connector-mysql --strip-components=1 \
 && rm -f /tmp/debezium-plugin.tar.gz \
 && curl -fLo /tmp/redis-plugin.zip \
         "https://github.com/redis-field-engineering/redis-kafka-connect/releases/download/v1.1.0/redis-redis-kafka-connect-1.1.0.zip" \
 && mkdir -p /opt/kafka/plugins/redis-kafka-connect \
 && cd /opt/kafka/plugins/redis-kafka-connect \
 && jar xf /tmp/redis-plugin.zip \
 && mv /opt/kafka/plugins/redis-kafka-connect/redis-redis-kafka-connect-1.1.0/lib/* \
    /opt/kafka/plugins/redis-kafka-connect/ 2>/dev/null || true \
 && rm -rf /opt/kafka/plugins/redis-kafka-connect/redis-redis-kafka-connect-1.1.0 \
 && rm -f /tmp/redis-plugin.zip

# Strimzi 镜像默认用非 root 用户
USER 1001
