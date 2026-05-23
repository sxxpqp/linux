# Kafka

Kafka 集群部署（StatefulSet + Strimzi Operator）。

## 文件说明

| 文件/目录 | 说明 |
|---|---|
| [sts.yaml](sts.yaml) | Kafka StatefulSet 部署：持久化存储声明模板、Kafka broker 配置 |
| [deploy.yaml](deploy.yaml) | Kafka 部署 YAML |
| [operator/](operator/) | Strimzi Kafka Operator 部署：Kafka CRD 定义（kafka.strimzi.io/v1beta2），3 节点集群配置 |
