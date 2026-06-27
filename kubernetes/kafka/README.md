# Kafka

两套部署方案,**推荐 Strimzi Operator**(KRaft 模式,无 ZooKeeper):

| 方案 | 目录 | 说明 |
|---|---|---|
| **Strimzi Operator**(推荐) | [operator/](operator/) | operator 管理 Kafka CR,KRaft + NodePool,生产用这个 |
| 手搓 StatefulSet(老) | [one/sts.yaml](one/sts.yaml) | 非 Operator,PVC + Headless Service + STS,学习/参考 |

应用场景:

| 场景 | 目录 |
|---|---|
| **MySQL → Redis 实时同步**(Debezium CDC,整行镜像做缓存) | [cdc-mysql-redis/](cdc-mysql-redis/) |

## Strimzi 部署(operator/)

| 文件 | 内容 |
|---|---|
| [operator/operator-install.yaml](operator/operator-install.yaml) | operator 静态清单(helm chart 1.0.1 渲染)。**备用**:离线 / GitOps 才用;**首选 `helm install`**(见下),失效了用 `helm template ... --include-crds` 重渲染 |
| [operator/kafka-cluster.yaml](operator/kafka-cluster.yaml) | **Kafka 集群 CR — 标准 internal**(集群内访问,**常用/默认**)。CDC、业务 Pod 等集群内组件用这个 |
| [operator/deploy-nodeport.yaml](operator/deploy-nodeport.yaml) | **Kafka 集群 CR — nodeport 变体**(集群**外**客户端访问才用,特殊情况) |

> ⚠ 选哪个集群 CR:**集群内访问(含 CDC)→ `kafka-cluster.yaml`(标准)**;只有 k8s 集群外的客户端要连才用 `deploy-nodeport.yaml`(nodeport)。两个同名 `kafka-cluster`,**二选一,别同时 apply**。

### 安装顺序(operator 先,集群后)

```bash
# === 第 1 步:装 operator ===
# 【首选】helm 在线直装(机器能连 quay.io)
helm install strimzi-cluster-operator oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  --namespace kafka --create-namespace
# ⚠ 必须带 --namespace kafka:operator 默认只 watch 自己所在 ns,否则看不到 kafka ns 里的 Kafka CR

# 【备用】离线 / GitOps 才用静态清单(跟 helm 二选一)
# kubectl create namespace kafka
# kubectl apply -f operator/operator-install.yaml

# 等 operator ready
kubectl -n kafka rollout status deploy/strimzi-cluster-operator

# === 第 2 步:先给节点打标签(集群 CR 里 nodeSelector kafka=true)===
kubectl label node <node> kafka=true --overwrite

# === 第 3 步:建 Kafka 集群(集群内访问用标准版)===
kubectl apply -f operator/kafka-cluster.yaml
# 集群外访问改用:kubectl apply -f operator/deploy-nodeport.yaml
kubectl -n kafka get kafka,kafkanodepool,pod -w
```

> **helm 拉 chart ≠ 走 containerd mirror**:`oci://quay.io/...` 是 helm 自己的 client 直连 quay.io 拉 chart;operator 镜像 `quay.io/strimzi/operator:1.0.1` 才是 kubelet/containerd 拉、走 quay mirror。

### NodePort 接入(deploy-nodeport.yaml 已配)

集群外连 Kafka 走 nodeport listener(端口 / advertisedHost 在 deploy-nodeport.yaml 里),bootstrap `32092`,各 broker `32093/32095/32096`。改 `advertisedHost` 为节点真实 IP。

## CDC:MySQL → Redis 实时同步

`MySQL binlog → Debezium 源 → Kafka topic → Redis Sink → 每行一个 HASH key`,删除→tombstone→Redis DEL(整行镜像做缓存)。完整步骤(MySQL 前置 / Nexus 上传 / 部署 / 验证 / 踩坑)见 **[cdc-mysql-redis/](cdc-mysql-redis/)**。

组件版本(已钉死、源码核对):

| 组件 | 版本 | 依据 |
|---|---|---|
| Strimzi operator | 1.0.1 | helm chart appVersion |
| Kafka | 4.2.0 | 集群 CR |
| Debezium MySQL 连接器 | **3.5.2.Final** | maven-metadata 最新 Final,基于 kafka-clients 4.1.2(对 4.2 集群 4.x 内兼容) |
| Redis Kafka 连接器 | **1.1.0** | redis-field-engineering 最新 release |

## 监控(可选)

集群 CR 默认**没开** metrics。要监控,在 `spec.kafka` 下加两段(指标只是被**暴露**,还要 Prometheus + PodMonitor 才会被抓):

| 加什么 | 暴露端口 | 抓什么 |
|---|---|---|
| `spec.kafkaExporter: {}` | 9308 | **消费组 lag** / offset / topic(lag 告警必备) |
| `spec.kafka.metricsConfig`(jmxPrometheusExporter + ConfigMap) | 9404 | broker/JVM/KRaft 内部指标 |

完整链路:`metrics 配置(暴露)` → `PodMonitor(告诉 Prometheus 抓)` → `Prometheus` → `Grafana`。
PodMonitor + Grafana 仪表盘见上游 `examples/metrics/`(strimzi-pod-monitor.yaml / grafana-dashboards/)。

> 参考样本:[kafka-metrics.yaml](https://github.com/strimzi/strimzi-kafka-operator/blob/1.0.1/examples/metrics/kafka-metrics.yaml) / 标准最简集群:[kafka-ephemeral.yaml](https://github.com/strimzi/strimzi-kafka-operator/blob/1.0.1/examples/kafka/kafka-ephemeral.yaml)
