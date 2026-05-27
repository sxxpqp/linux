# Grafana Alloy 安装步骤（生产环境）

Grafana Alloy 以 DaemonSet 方式部署，作为 OTLP 接入层，接收 OTel SDK 和 Beyla eBPF 的 Trace/Metrics，加工后分发到 Tempo 和 Prometheus。

## 部署架构

```text
                          ┌────────────────────────────────────────┐
                          │      Grafana Alloy (DaemonSet)          │
                          │                                        │
  OTLP (4317/4318) ──────→│  otelcol.receiver.otlp                 │
                          │       │                                │
                          │       ├─→ servicegraph connector        │ → 拓扑指标 → batch → Prometheus
                          │       ├─→ spanmetrics connector         │ → RED 指标 → batch → Prometheus
                          │       └─→ batch processor               │ → Tempo
                          └────────────────────────────────────────┘
```

## 前置条件

- Kubernetes 集群
- Tempo 已部署（`tempo-distributor.observability:4317`）
- Prometheus 已部署并开启 remote_write（`prometheus-kube-prometheus-prometheus.monitoring.svc:9090/api/v1/write`）
- 内核 ≥ 5.14（如需 Beyla eBPF）

---

## 1. 创建 ConfigMap

```bash
kubectl create configmap alloy-config -n observability \
  --from-file=config.alloy=config.alloy \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## 2. 部署 Alloy DaemonSet + Service

```bash
kubectl apply -f ../observability/alloy.yaml
kubectl wait --for=condition=ready pod -l app=alloy -n observability --timeout=120s
```

---

## 3. 关键配置说明

### 3.1 配置块职责

| 配置块 | 作用 |
|---|---|
| `otelcol.receiver.otlp` | 接收 OTLP Trace，三路分发到 connectors + batch |
| `otelcol.connector.servicegraph` | 内存中计算调用链上下游关系，生成拓扑指标 |
| `otelcol.connector.spanmetrics` | 统计 QPS、延迟、错误率（RED 指标） |
| `otelcol.processor.batch (traces)` | Trace 攒批，`512 条 / 5s` 批量发送，减少 Tempo 压力 |
| `otelcol.processor.batch (metrics)` | 指标攒批，`512 条 / 5s` 批量发送 |
| `otelcol.exporter.otlp "tempo"` | 原始 Trace → Distributor (`tempo-distributor.observability:4317`) |
| `otelcol.exporter.prometheus` | OTel 指标 → Prometheus 格式 |
| `prometheus.remote_write` | 指标 → Prometheus (`prometheus.observability:9090/api/v1/write`) |

### 3.2 流水线示意

```text
app/Beyla → Alloy(4317/4318)
               │
               ├─→ servicegraph ──→ batch(metrics) ──→ Prometheus (拓扑)
               ├─→ spanmetrics  ──→ batch(metrics) ──→ Prometheus (RED)
               └─→ batch(traces) ──→ Tempo (原始 Trace 存储)
```

### 3.3 DaemonSet 关键设计

| 项 | 做法 | 原因 |
|----|------|------|
| Tempo 地址 | `tempo.observability:4317` | Service DNS 自动负载均衡到 3 个 Tempo Pod |
| hostPort | 4317 / 4318 | Pod 通过节点 IP 就近发送，不经过 Service 跳转 |
| hostPort 不冲突 | DaemonSet 每节点一个 | 同节点只有一个 Alloy Pod 监听 |

---

## 4. 更新配置（热加载）

Alloy 配置更新不需要重启，修改 ConfigMap 后自动重载：

```bash
kubectl create configmap alloy-config -n observability \
  --from-file=config.alloy=config.alloy \
  --dry-run=client -o yaml | kubectl apply -f -

# 等待自动重载（约 30s），查看日志确认
kubectl logs -n observability -l app=alloy --since=30s --tail=10
```

---

## 5. 验证

```bash
# 查看 Pod
kubectl -n observability get pods -l app=alloy

# 查看日志（确认 pipeline 启动成功）
kubectl -n observability logs -l app=alloy --tail=30

# 确认端口监听
kubectl exec -n observability -l app=alloy -- ss -tlnp | grep -E "4317|4318"

# 测试发送 Trace
kubectl -n observability port-forward svc/alloy 4318:4318 &
curl -XPOST -H "Content-Type: application/json" \
  http://localhost:4318/v1/traces \
  -d '{"resourceSpans":[]}'

# 确认指标已写入 Prometheus
kubectl -n observability port-forward svc/prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/label/__name__/values' | jq '.data[]' | grep -E "spanmetrics|service_graph"
```

---

## 6. 常见问题

### Alloy 连不上 Tempo

```bash
# 确认 Service DNS 可解析
kubectl run -it --rm debug --image=busybox -n observability -- nslookup tempo-distributor.observability

# 确认 Distributor 4317 端口在监听
kubectl exec -n observability deploy/tempo-distributor -- ss -tlnp | grep 4317
```

### 指标没写入 Prometheus

```bash
# 确认 remote_write endpoint 可达
kubectl run -it --rm debug --image=busybox -n observability -- \
  wget -qO- http://prometheus-kube-prometheus-prometheus.monitoring.svc:9090/api/v1/status/config | head -20

# 确认 Prometheus 开启了 remote_write receiver
# kube-prometheus-stack 默认 --web.enable-remote-write-receiver
```

### Alloy 热加载不生效

```bash
# 强制重启
kubectl rollout restart daemonset alloy -n observability
kubectl wait --for=condition=ready pod -l app=alloy -n observability --timeout=60s
```

---

## 7. 文件索引

| 文件 | 用途 |
|---|---|
| [config.alloy](config.alloy) | Alloy OTLP 流水线配置（含 batch 攒批） |
| [alloy.yaml](../observability/alloy.yaml) | DaemonSet + Service K8s 资源定义 |
