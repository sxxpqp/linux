# Kafka — Strimzi Operator 部署(KRaft,无 ZooKeeper)

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/kafka/README.md
> 状态: 学习笔记(YAML 已落盘,未在集群跑全流程验证)

Strimzi operator 托管的 Kafka **4.2.0**(KRaft 模式)。operator 装一次,之后集群 / 外部访问 / Connect / Topic 全部用 CR 声明,不手搓 StatefulSet。

## TL;DR

```bash
# 1. 装 operator(首选 helm;必须 --namespace kafka,否则 operator 看不到集群 CR)
helm install strimzi-cluster-operator oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  --namespace kafka --create-namespace
kubectl -n kafka rollout status deploy/strimzi-cluster-operator

# 2. 给 3 个 kafka 节点打标签(集群 CR 用 nodeSelector kafka=true + 反亲和,每节点 1 broker)
kubectl label node <node1> <node2> <node3> kafka=true --overwrite

# 3. 建集群 —— 集群内访问(常用,含 CDC):
kubectl apply -f operator/kafka-cluster.yaml
#       集群外客户端访问(特殊):
# kubectl apply -f operator/deploy-nodeport.yaml
kubectl -n kafka get kafka,kafkanodepool,pod -w     # kafka-cluster READY=True 即成

# 验证内部可达
kubectl -n kafka run kcat --rm -it --image=edenhill/kcat:1.7.1 --restart=Never -- \
  -b kafka-cluster-kafka-bootstrap:9092 -L
```

## 架构

```
            helm install(首选) / operator-install.yaml(备用)
                          │
                          ▼
              strimzi-cluster-operator        watch ns = kafka
                          │  reconcile 下面的 CR
        ┌─────────────────┼──────────────────────┐
        ▼                 ▼                       ▼
     Kafka CR        KafkaNodePool          KafkaConnector
  listener/config   broker+controller     Debezium 源 / Redis 汇
        │            (KRaft 合并)                 │
        ▼                                         ▼
  ┌──────────┐  ┌──────────┐  ┌──────────┐   MySQL→Redis CDC
  │ node1    │  │ node2    │  │ node3    │   (见 cdc-mysql-redis/)
  │ broker+  │  │ broker+  │  │ broker+  │
  │ ctrl     │  │ ctrl     │  │ ctrl     │   kafka=true + 反亲和
  └──────────┘  └──────────┘  └──────────┘   → 每节点 1 broker
        └─────────────┬──────────────┘
                      ▼
         kafka-cluster-kafka-bootstrap:9092   ← 集群内统一入口
```

## 目录 / 文件

| 路径 | 内容 |
|---|---|
| [operator/operator-install.yaml](operator/operator-install.yaml) | operator 静态清单(helm chart 1.0.1 渲染)。**备用**:离线 / GitOps 才用,首选 `helm install` |
| [operator/kafka-cluster.yaml](operator/kafka-cluster.yaml) | **Kafka 集群 CR — 标准 internal**(集群内访问,**常用/默认**) |
| [operator/deploy-nodeport.yaml](operator/deploy-nodeport.yaml) | Kafka 集群 CR — **nodeport 变体**(集群外客户端访问才用) |
| [cdc-mysql-redis/](cdc-mysql-redis/) | **MySQL → Kafka → Redis 实时同步**(Debezium CDC,整行镜像做缓存) |
| [one/sts.yaml](one/sts.yaml) | 老的手搓 StatefulSet 版(非 Operator,仅参考) |

## 安装

### 第 1 步:装 operator

| 方式 | 命令 | 适合 |
|---|---|---|
| **helm(首选)** | `helm install strimzi-cluster-operator oci://quay.io/strimzi-helm/strimzi-kafka-operator -n kafka --create-namespace` | 在线、能连 quay.io |
| 静态清单(备用) | `kubectl create ns kafka && kubectl apply -f operator/operator-install.yaml` | 离线 / GitOps |

> - ⚠ **必须 `--namespace kafka`**:operator 默认只 watch 自己所在 ns,不带就看不到 kafka ns 里的 Kafka CR。
> - **helm 拉 chart 不走 containerd mirror**:`oci://quay.io/...` 是 helm 自己 client 直连 quay.io;operator 镜像 `quay.io/strimzi/operator:1.0.1` 才是 kubelet 拉、走 quay mirror。

### 第 2 步:打节点标签

```bash
kubectl label node <node1> <node2> <node3> kafka=true --overwrite
```

集群 CR 里 `nodeSelector: kafka=true` + 硬反亲和(每节点最多 1 broker)。**3 节点 → KRaft 合并模式**(broker+controller 同 pool):官方分离 pool 是 controller×3 + broker×3 = 6 pod,3 个节点放不下,合并模式才对。

### 第 3 步:建集群(二选一)

| 集群 CR | listener | 何时用 |
|---|---|---|
| **`kafka-cluster.yaml`** | internal(plain 9092 / tls 9093) | **集群内访问(默认,含 CDC、业务 Pod)** |
| `deploy-nodeport.yaml` | internal + **nodeport** | k8s **集群外**的客户端要连才用 |

> 两个集群同名 `kafka-cluster`,**二选一,别同时 apply**。nodeport 变体里 `advertisedHost` 要填节点真实 IP,bootstrap `32092` / broker `32093/32095/32096`。

## 验证

```bash
# 1. 组件 ready
kubectl -n kafka get kafka,kafkanodepool,pod
# kafka-cluster READY=True;每节点 1 个 kafka-cluster-kafka-<n> pod

# 2. 集群内连通 + 列元数据
kubectl -n kafka run kcat --rm -it --image=edenhill/kcat:1.7.1 --restart=Never -- \
  -b kafka-cluster-kafka-bootstrap:9092 -L

# 3. 收发测试
kubectl -n kafka run kcat --rm -it --image=edenhill/kcat:1.7.1 --restart=Never -- \
  -b kafka-cluster-kafka-bootstrap:9092 -P -t test    # 输入几行后 Ctrl-D
kubectl -n kafka run kcat --rm -it --image=edenhill/kcat:1.7.1 --restart=Never -- \
  -b kafka-cluster-kafka-bootstrap:9092 -C -t test -e
```

## CDC:MySQL → Redis 实时同步

`MySQL binlog → Debezium 源 → Kafka topic → Redis Sink → 每行一个 HASH key`,删除→tombstone→Redis DEL(整行镜像做缓存)。完整步骤见 **[cdc-mysql-redis/](cdc-mysql-redis/)**。

组件版本(已钉死、源码核对):

| 组件 | 版本 | 依据 |
|---|---|---|
| Strimzi operator | 1.0.1 | helm chart appVersion |
| Kafka | 4.2.0 | 集群 CR |
| Debezium MySQL 连接器 | **3.5.2.Final** | maven-metadata 最新 Final,基于 kafka-clients 4.1.2(对 4.2 集群 4.x 内兼容) |
| Redis Kafka 连接器 | **1.1.0** | redis-field-engineering 最新 release |

## 监控(可选)

集群 CR 默认**没开** metrics。指标只是被**暴露**,还要 Prometheus Operator + PodMonitor 才会被抓:

| 在 Kafka CR 加 | 暴露端口 | 抓什么 |
|---|---|---|
| `spec.kafkaExporter: {}` | 9308 | **消费组 lag** / offset / topic(lag 告警必备) |
| `spec.kafka.metricsConfig`(jmxPrometheusExporter + ConfigMap) | 9404 | broker / JVM / KRaft 内部指标 |

链路:`metrics 配置(暴露)` → `PodMonitor(告诉 Prometheus 抓)` → `Prometheus` → `Grafana`。
PodMonitor + 仪表盘见上游 `examples/metrics/`(`prometheus-install/pod-monitors/` + `grafana-dashboards/`),namespace 记得改成 `kafka`。

## 踩坑

| 现象 | 原因 | 修法 |
|---|---|---|
| `KafkaNodePool ... unknown field "spec.template.pod.nodeSelector"` | Strimzi pod template **没有 `nodeSelector`** 字段;`v1` 严格解码直接拒绝未知字段 | 节点选择改用 `affinity.nodeAffinity`(本仓库 yaml 已修)。Kafka CR 可能已先创建成功,改完 `kubectl apply` 重跑即可补上 nodepool |
| Pod 卡 `ImagePullBackOff`(quay.io/strimzi/operator) | 节点没配 quay mirror | `bash docker/containerd/mirrors.sh` + `systemctl restart containerd`,**别改 image** |
| operator 起来了但 Kafka CR 不 reconcile | helm 没带 `--namespace kafka`,operator watch 错 ns | 重装带 `--namespace kafka`,或确认 `STRIMZI_NAMESPACE` |
| broker pod Pending | 标签没打 / `longhorn` storageClass 不存在 / 节点 < 3 | `kubectl get sc`;`kubectl label node ... kafka=true`;3 节点用合并 pool |
| broker 都起了,但 **entity-operator** Pending(`didn't satisfy existing pods anti-affinity`) | broker 反亲和选择器若用 `strimzi.io/cluster`(太宽),会把 entity-operator 也算进去 → 所有 broker 节点拒绝它 | 选择器收窄到只匹配 broker:`strimzi.io/name: kafka-cluster-kafka`(或 `strimzi.io/pool-name: kafka`),本仓库 yaml 已修 |
| 节点不够(如 1 control-plane + 2 worker)第 3 broker Pending | 硬反亲和要 3 个可调度节点,CP 有 NoSchedule 污点 | 加节点(`kubeadm join`),或 nodepool `template.pod.tolerations` 容忍 control-plane 污点拉上 CP,或减副本 |
| nodeport 集群外连不上某 broker | `advertisedHost` 写的 IP 跟 broker 实际落点不符 | advertisedHost 改成 broker 实际所在节点 IP(详见上次排查) |
| `auto.create.topics.enable=false` 下生产报 topic 不存在 | 集群 CR 关了自动建 topic | 用 `KafkaTopic` CR 显式建,或临时开自动建 |

## 参考

- 上游: https://github.com/strimzi/strimzi-kafka-operator
- 兼容性 / 示例: `examples/kafka/`(kafka-persistent.yaml 等) / `examples/metrics/`
