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
| [operator/deploy-nodeport.yaml](operator/deploy-nodeport.yaml) | **Strimzi operator 安装清单**(CRD + RBAC + Deployment,helm chart 1.0.1 渲染,watch ns=kafka) |
| [operator/deploy.yaml](operator/deploy.yaml) | **Kafka 集群 CR**(`kind: Kafka` + `KafkaNodePool`,nodeport listener,持久盘 longhorn,3 broker) |

> ⚠ 命名注意:`deploy-nodeport.yaml` 是 **operator 本体**,`deploy.yaml` 才是 **Kafka 集群**,跟文件名直觉相反。

### 安装顺序(operator 先,集群后)

```bash
# === 第 1 步:装 operator ===
# 方式 A:在线 helm 直接装(机器能连 quay.io)
helm install strimzi-cluster-operator oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  --namespace kafka --create-namespace
# ⚠ 必须带 --namespace kafka:operator 默认只 watch 自己所在 ns,否则看不到 kafka ns 里的 Kafka CR

# 方式 B:apply 归档清单(离线 / GitOps,跟 A 二选一)
kubectl create namespace kafka
kubectl apply -f operator/deploy-nodeport.yaml

# 等 operator ready
kubectl -n kafka rollout status deploy/strimzi-cluster-operator

# === 第 2 步:先给节点打标签(deploy.yaml 里 nodeSelector kafka=true)===
kubectl label node <node> kafka=true --overwrite

# === 第 3 步:建 Kafka 集群 ===
kubectl apply -f operator/deploy.yaml
kubectl -n kafka get kafka,kafkanodepool,pod -w
```

> **helm 拉 chart ≠ 走 containerd mirror**:`oci://quay.io/...` 是 helm 自己的 client 直连 quay.io 拉 chart;operator 镜像 `quay.io/strimzi/operator:1.0.1` 才是 kubelet/containerd 拉、走 quay mirror。

### NodePort 接入(deploy.yaml 已配)

集群外连 Kafka 走 nodeport listener(端口 / advertisedHost 在 deploy.yaml 里),bootstrap `32092`,各 broker `32093/32095/32096`。改 `advertisedHost` 为节点真实 IP。

## 监控(可选)

`deploy.yaml` 默认**没开** metrics。要监控,在 `spec.kafka` 下加两段(指标只是被**暴露**,还要 Prometheus + PodMonitor 才会被抓):

| 加什么 | 暴露端口 | 抓什么 |
|---|---|---|
| `spec.kafkaExporter: {}` | 9308 | **消费组 lag** / offset / topic(lag 告警必备) |
| `spec.kafka.metricsConfig`(jmxPrometheusExporter + ConfigMap) | 9404 | broker/JVM/KRaft 内部指标 |

完整链路:`metrics 配置(暴露)` → `PodMonitor(告诉 Prometheus 抓)` → `Prometheus` → `Grafana`。
PodMonitor + Grafana 仪表盘见上游 `examples/metrics/`(strimzi-pod-monitor.yaml / grafana-dashboards/)。

> 参考样本:[kafka-metrics.yaml](https://github.com/strimzi/strimzi-kafka-operator/blob/1.0.1/examples/metrics/kafka-metrics.yaml) / 标准最简集群:[kafka-ephemeral.yaml](https://github.com/strimzi/strimzi-kafka-operator/blob/1.0.1/examples/kafka/kafka-ephemeral.yaml)
