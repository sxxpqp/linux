# Grafana LGTM + Beyla 生产环境部署指南

## 架构概览

```
                               ┌────────────────────┐
                               │  MinIO (S3 共享存储) │
                               │  9000               │
                               └──────────┬─────────┘
                                          │ S3 读写
                          ┌───────────────┼───────────────┐
                          ▼               ▼               ▼
                    ┌──────────┐  ┌──────────┐  ┌──────────┐
                    │ Tempo-0  │  │ Tempo-1  │  │ Tempo-2  │   ← 3 副本
                    │ :4317    │  │ :4317    │  │ :4317    │
                    └────┬─────┘  └────┬─────┘  └────┬─────┘
                         │   OTLP      │              │
                         └─────────┬────┴─────────────┘
                                   │ tempo.observability:4317  ← Service DNS 负载均衡
                                   ▲
            ┌──────────────────────┼──────────────────────┐
            │  Node 1              │  Node 2              │
            │                      │                      │
            │  ┌──────────────┐    │  ┌──────────────┐    │
            │  │  Alloy  Pod  │    │  │  Alloy  Pod  │    │  ← DaemonSet
            │  │  :4317 gRPC  │    │  │  :4317 gRPC  │    │
            │  │  :4318 HTTP  │    │  │  :4318 HTTP  │    │
            │  └──────▲───────┘    │  └──────▲───────┘    │
            │         │            │         │            │
            │    OTLP │            │    OTLP │            │
            │         │            │         │            │
            │  ┌──────┴───────┐    │  ┌──────┴───────┐    │
            │  │  Beyla Pod   │    │  │  Beyla Pod   │    │  ← DaemonSet
            │  │  hostNetwork │    │  │  hostNetwork │    │
            │  └──────▲───────┘    │  └──────▲───────┘    │
            │         │ eBPF       │         │ eBPF       │
            │  ┌──────┴───────┐    │  ┌──────┴───────┐    │
            │  │  应用 Pod     │    │  │  应用 Pod     │    │
            │  │  (零侵入)     │    │  │  (零侵入)     │    │
            │  └──────────────┘    │  └──────────────┘    │
            └──────────────────────┴──────────────────────┘

                          ┌───────────────────────────┐
                          │  Grafana (Helm)           │
                          │  NodePort:30300           │
                          │                           │
                          │  数据源：                  │
                          │  Tempo ← Traces            │
                          │  Loki  ← Logs              │
                          │  Mimir/Prometheus ← Metrics│
                          └───────────────────────────┘
```

| 组件 | 部署方式 | 作用 | 副本数 |
|------|---------|------|--------|
| **Beyla** | DaemonSet | eBPF 零侵入，自动生成 Trace + Metrics | 每节点 1 |
| **Alloy** | DaemonSet | OTLP 接收 → 攒批 → 转发 Tempo | 每节点 1 |
| **Tempo** | Deployment (Helm) | Trace 存储 | 3 |
| **MinIO** | Deployment | S3 共享存储，Tempo 后端 | 1 |
| **Grafana** | Deployment (Helm) | 统一可视化 | 1 |

> **高可用要点**：Tempo 3 副本共享 MinIO S3 存储；Alloy 通过 Service DNS `tempo.observability:4317` 自动负载均衡；任意一个 Tempo Pod 挂了不影响全链路。


```
{
  "timestamp": "2026-05-27T02:52:01.548Z",
  "level": "INFO",
  "service_name": "otel-demo",
  "service_version": "1.0.0",
  "environment": "production",

  "trace_id": "6a2d0abfb93ad433dbf78fec0ec2eff3",
  "span_id": "8f3c2b1a0d9e4f7b",
  "trace_flags": "01",

  "msg": "User login successfully",
  "user_id": "10086",
  "http_method": "POST",
  "http_path": "/api/login",
  "http_status": 200,
  "duration_ms": 23,

  "k8s_namespace": "default",
  "k8s_pod": "otel-demo-xxx",
  "k8s_node": "node-1"
}
```
---

## 部署顺序

```
1. Cert Manager → 2. 命名空间 → 3. MinIO → 4. Tempo → 5. Alloy → 6. Beyla → 7. Grafana
```

---

## 前置条件

### Cert Manager

```bash
kubectl apply -f cert-manager/cert-manager.yaml
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager --timeout=120s
```

---

## 1. 创建命名空间

```bash
kubectl create namespace observability
```

---

## 2. 部署 MinIO（S3 共享存储）

```bash
kubectl apply -f minio.yaml
kubectl wait --for=condition=ready pod -l app=minio -n observability --timeout=120s

# 确认 bucket 创建成功
kubectl logs -n observability -l job-name=minio-create-bucket
# 预期：bucket tempo-traces ready
```

> `minio.yaml` 包含 PVC + Deployment + Service + 自建 bucket 的 Job，见 [minio.yaml](minio.yaml)。

---

## 3. 部署 Tempo（3 副本 + S3 后端）

### 3.1 Helm 安装

```bash
helm repo add grafana https://nexus.ihome.sxxpqp.top:8443/repository/grafana/
helm repo update

helm install tempo grafana/tempo-distributed \
  --namespace observability \
  --values tempo-values.yaml
```

### 3.2 values 文件

> 完整配置见 [tempo-values.yaml](tempo-values.yaml)。核心变更：`replicas: 3` + `backend: s3`。

### 3.3 验证

```bash
kubectl get pods -n observability -l app.kubernetes.io/name=tempo
# 预期 3 个 Running

kubectl port-forward svc/tempo-query-frontend -n observability 3200:3200 &
curl http://localhost:3200/ready   # 返回 200
```

---

## 4. 部署 Alloy（OTel 采集管道）

### 4.1 创建 ConfigMap

```bash
kubectl create configmap alloy-config -n observability \
  --from-file=config.alloy=alloy-config.alloy
```

### 4.2 配置说明

```alloy
// alloy-config.alloy
otelcol.receiver.otlp "default" {
  grpc  { endpoint = "0.0.0.0:4317" }
  http  { endpoint = "0.0.0.0:4318" }
  output {
    traces  = [otelcol.processor.batch.traces.input]
    metrics = [otelcol.processor.batch.metrics.input]
    logs    = [otelcol.processor.batch.logs.input]
  }
}

otelcol.processor.batch "traces" {
  send_batch_size = 512
  timeout         = "5s"
  output {
    traces = [otelcol.exporter.otlp.tempo.input]
  }
}

otelcol.processor.batch "metrics" {
  send_batch_size = 512
  timeout         = "5s"
  output {
    metrics = [otelcol.exporter.otlphttp.prometheus.input]
  }
}

otelcol.processor.batch "logs" {
  send_batch_size = 512
  timeout         = "5s"
  output {
    logs = [otelcol.exporter.otlphttp.loki.input]
  }
}

// Traces → Tempo (gRPC)
otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo-distributor.observability:4317"
    tls { insecure = true }
  }
}

// Metrics → Prometheus OTLP endpoint
otelcol.exporter.otlphttp "prometheus" {
  client {
    endpoint = "http://prometheus-kube-prometheus-prometheus.monitoring.svc:9090/api/v1/otlp"
    tls { insecure = true }
  }
}

// Logs → Loki OTLP endpoint（主路径：OTel SDK 发出的日志）
otelcol.exporter.otlphttp "loki" {
  client {
    endpoint = "http://loki-gateway.monitoring.svc:80/otlp"
    tls { insecure = true }
  }
}

// 文件采集日志（兜底：非 OTel SDK 的容器日志）
local.file_match "pod_logs" { ... }
loki.source.file "pod_logs" { ... }
loki.process "labels" { ... }
loki.write "default" {
  endpoint {
    url = "http://loki-gateway.monitoring.svc:80/loki/api/v1/push"
  }
}
```

> 配置要点：
> - Alloy 做纯转发，不再运行 servicegraph/spanmetrics connectors
> - RED + 拓扑指标由 **Tempo metrics-generator** 生成（tempo-values.yaml 中 `metricsGenerator.enabled: true`）
> - Metrics 走 OTLP HTTP → Prometheus `/api/v1/otlp`（需在 Prometheus CRD 中开启 `otlp-write-receiver`）
> - Logs 双通道：OTel SDK 发 OTLP → Loki `/otlp`（主），非 OTel 容器走文件采集 → Loki Gateway（兜底）

### 4.3 部署 Alloy

```bash
# ConfigMap + DaemonSet + Service 已合并在 alloy.yaml 中，一个文件部署
kubectl apply -f alloy.yaml
kubectl wait --for=condition=ready pod -l app=alloy -n observability --timeout=120s
```

### 4.4 关键设计

| 项 | 做法 | 原因 |
|----|------|------|
| Tempo 地址 | `tempo-distributor.observability:4317` | Service DNS → Distributor，Trace 写入入口 |
| hostPort | 4317 / 4318 | Pod 通过节点 IP 就近发送，不经过 Service 跳转 |
| 不设资源 limit | Beyla 改用 Service DNS 发 | 避免 IP 变化导致 Beyla 得改配置 |

---

## 5. 部署 Beyla（eBPF 自动埋点）

```bash
kubectl apply -f beyla.yaml
kubectl rollout status daemonset/beyla -n observability --timeout=120s
```

> beyla.yaml 包含 ServiceAccount + ClusterRole + ClusterRoleBinding + ConfigMap + DaemonSet，见 [beyla.yaml](beyla.yaml)。

---

## 6. 部署 Grafana

### 6.1 Helm 安装

```bash
helm upgrade --install grafana grafana/grafana \
  --namespace observability \
  --values grafana-values.yaml
```

### 6.2 values 文件

> 完整配置见 [grafana-values.yaml](grafana-values.yaml)。NodePort:30300，Tempo 数据源连 `tempo.observability:3200`。

---

## 7. 验证全链路

### 7.1 确认所有组件

```bash
kubectl get pods -n observability
# 预期：
# minio-xxxxx            1/1 Running
# tempo-0                1/1 Running
# tempo-1                1/1 Running
# tempo-2                1/1 Running
# alloy-xxxxx            1/1 Running  (每节点)
# beyla-xxxxx            1/1 Running  (每节点)
# grafana-xxxxx          1/1 Running
```

### 7.2 确认 MinIO bucket 就绪

```bash
kubectl logs -n observability -l app=minio | grep bucket
kubectl port-forward svc/minio -n observability 9001:9001 &
# 浏览器打开 http://localhost:9001  → 用 minioadmin / minioadmin 登录
# 确认 Buckets 里有 tempo-traces
```

### 7.3 确认 Tempo 在写数据

```bash
kubectl logs -n observability tempo-0 | grep -i "trace\|ingester\|written"
```

### 7.4 确认 Beyla 发现服务

```bash
kubectl logs -n observability -l app=beyla | grep -i "instrument\|trace"
# 预期：instrumenting service default/xxx
```

### 7.5 确认 Alloy 转发正常

```bash
kubectl logs -n observability -l app=alloy --tail=20
# 预期：Exporting traces 等日志
```

### 7.6 访问 Grafana

```
浏览器打开：http://<任意节点IP>:30300
登录：admin / admin123
Explore → 数据源选 Tempo → Search → Find Traces
```

---

## 8. 与测试环境对比

| | 测试环境（OTel Operator） | 生产环境（Beyla + LGTM） |
|---|---|---|
| **埋点方式** | javaagent initContainer 注入 | eBPF 内核拦截，零侵入 |
| **需改代码** | 否 | 否 |
| **需改镜像** | 否 | 否 |
| **支持语言** | Java / Node.js / Python / .NET | **任意语言**（eBPF 协议层） |
| **采集器** | OTel Collector | Alloy |
| **Trace 存储** | Jaeger | Tempo（3 副本 + MinIO S3） |
| **高可用** | 无（单 Jaeger Pod） | ✅ Tempo 多副本 + S3 |
| **开销** | ~5% CPU | ~2% CPU |

---

## 9. 常见问题

### MinIO bucket 创建失败

```bash
kubectl logs -n observability -l job-name=minio-create-bucket
# 如果提示 connection refused，手动创建：
kubectl exec -n observability deploy/minio -- mc alias set local http://localhost:9000 minioadmin minioadmin
kubectl exec -n observability deploy/minio -- mc mb local/tempo-traces --ignore-existing
```

### Tempo 连不上 MinIO

```bash
# 确认 MinIO Service DNS 可解析
kubectl run -it --rm debug --image=busybox -n observability -- nslookup minio.observability

# 确认 Tempo 日志没有 S3 报错
kubectl logs -n observability tempo-0 | grep -i "s3\|minio\|error"
```

### Alloy 连不上 Tempo

```bash
# 确认 Service DNS 可解析
kubectl run -it --rm debug --image=busybox -n observability -- nslookup tempo-distributor.observability

# 确认 Distributor 4317 端口在监听
kubectl exec -n observability deploy/tempo-distributor -- ss -tlnp | grep 4317
```

### Beyla 发现不了服务

```bash
# 内核版本
uname -r   # 需要 ≥ 5.14

# eBPF 支持
ls /sys/kernel/btf/vmlinux

# 确认监控的 namespace 有 Pod
kubectl get pods -n default
```

### Tempo 查询端口（3200）和 OTLP 端口（4317）的区别

| 端口 | 协议 | 用途 | 谁用 |
|------|------|------|------|
| 4317 | OTLP gRPC | 接收 Trace 数据 | Alloy → Distributor |
| 4318 | OTLP HTTP | 接收 Trace 数据 | 备用 |
| 3200 | HTTP | 查询 Trace | Grafana → Tempo |

---

## 10. 代码里保留 OTel SDK（互补）

Beyla 在 eBPF 层只能看 HTTP/gRPC 调用，如果要看 **SQL 查询、Redis、Kafka、方法级调用链**，代码里保留 OTel SDK：

```yaml
# 应用 Deployment 添加环境变量，让 SDK 往 Alloy 发
env:
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://alloy.observability:4318"
```

两条线并行，共用一套 Alloy + Tempo 管道：

```
Beyla (eBPF) → HTTP/gRPC 调用耗时，服务间拓扑
    +
代码 OTel SDK → SQL 查询、Redis、方法级 Trace
    ↓
Alloy → Tempo（统一存储）→ Grafana（统一展示）
```
