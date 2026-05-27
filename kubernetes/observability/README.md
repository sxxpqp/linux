# LGTM + Beyla 可观测性栈

基于 Grafana LGTM（Loki + Tempo + Mimir/Prometheus + Grafana）+ Alloy + Beyla 的统一可观测性平台。

## 架构

```
应用 Pod                                    Grafana (:30300)
  │                                           ▲
  ├─→ Beyla (eBPF) ──→ Alloy ──→ Tempo ──────┤  Trace 查询
  ├─→ OTel SDK ────→ Alloy ──→ Prometheus ───┤  指标关联
  └─→ stdout ──→ Alloy ──→ Loki ─────────────┤  日志关联
                         ↑                    │
                    MinIO (S3) ───────────────┘  共享存储
```

| 组件 | 部署方式 | 命名空间 | 端口 | 作用 |
|------|---------|---------|------|------|
| **MinIO** | Deployment | observability | 9000/9001 | S3 共享存储（Tempo 后端） |
| **Tempo** | Helm (tempo-distributed) | observability | 4317(OTLP) / 3200(query) | Trace 存储与查询 |
| **Alloy** | DaemonSet | observability | 4317/4318 | OTLP 接收 + 日志采集 + 指标生成 |
| **Beyla** | DaemonSet | observability | — | eBPF 零侵入自动埋点 |
| **Grafana** | Helm | observability | 30300(NodePort) | 统一可视化 |

> Prometheus（kube-prometheus-stack）在 `monitoring` 命名空间，Loki 在 `monitoring` 命名空间，跨命名空间通过 K8s Service DNS 互联。

## 数据流

```
Traces:  App/Beyla ──OTLP──→ Alloy ──→ Tempo Distributor (:4317) ──→ MinIO
                                 └──→ servicegraph/spanmetrics ──→ Prometheus (remote_write)

Logs:   容器 stdout ──→ /var/log/pods/ ──→ Alloy (loki.source.file) ──→ Loki Gateway

Metrics: Beyla ──OTLP──→ Alloy ──→ spanmetrics ──→ Prometheus remote_write
```

## 结构化 JSON 日志格式

otel-demo 应用输出结构化 JSON 日志，嵌入 OpenTelemetry 追踪上下文，实现日志→链路一键跳转：

```json
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

### 字段说明

| 字段 | 类别 | 说明 |
|------|------|------|
| `timestamp` | 标准字段 | ISO 8601 时间戳，Loki 以此排序 |
| `level` | 标准字段 | 日志级别（DEBUG/INFO/WARN/ERROR） |
| `msg` | 标准字段 | 日志消息正文 |
| `trace_id` | **OTel 上下文** | 32 位 hex，Grafana 用 `derivedFields` 提取后跳转 Tempo |
| `span_id` | **OTel 上下文** | 16 位 hex，标识本次调用在 trace 中的位置 |
| `trace_flags` | **OTel 上下文** | `01` = 采样，`00` = 未采样 |
| `service_name` | 服务标识 | 服务名，对应 OTel `service.name` |
| `service_version` | 服务标识 | 版本号，用于金丝雀/回滚分析 |
| `environment` | 服务标识 | 环境标签（production/staging） |
| `http_method` / `http_path` / `http_status` / `duration_ms` | 请求指标 | HTTP 请求详情，无 trace 时也能排查 |
| `user_id` | 业务字段 | 关联到具体用户 |
| `k8s_namespace` / `k8s_pod` / `k8s_node` | K8s 定位 | 与 Alloy 路径提取的 `namespace/pod/container` 互补 |

### Alloy 日志处理流水线

```
/var/log/pods/*/*/*.log
  → stage.cri         解包 containerd CRI 格式
  → stage.regex       从文件路径提取 namespace/pod/container
  → stage.json        解析 JSON 日志体，提取 level/service_name/k8s_namespace/environment/trace_id/span_id
  → stage.labels      低基数字段（level, service_name, service_namespace, deployment_environment_name）设为 Loki label
  → stage.structured_metadata  高基数字段（trace_id, span_id）设为结构化元数据
  → Loki Gateway
```

> `trace_id` 作为 **structured_metadata** 而非 label：trace_id 基数极高（每条 trace 唯一），设为 label 会导致 Loki 索引膨胀。structured_metadata 只索引不建 series，适合高基数字段。

### Grafana 日志→链路关联

Grafana 数据源配置中 Loki 的 `derivedFields` 从日志消息提取 `trace_id`：

```yaml
derivedFields:
  - name: TraceID
    matcherRegex: '"trace_id":"([a-f0-9]{32})"'
    url: '$${__value.raw}'
    datasourceUid: tempo
```

Explore Loki 日志时，每条带 `trace_id` 的日志行旁会出现 **Tempo** 按钮，点击直接跳转到完整调用链。

## 文件索引

### 核心部署

| 文件 | 说明 |
|------|------|
| [minio.yaml](minio.yaml) | MinIO Deployment + Service + PVC + 自动创建 bucket Job |
| [tempo-values.yaml](tempo-values.yaml) | Tempo Helm values：3 副本 + MinIO S3 + metrics-generator |
| [alloy.yaml](alloy.yaml) | Alloy DaemonSet + Service（ConfigMap 见 alloy-config.alloy） |
| [alloy-config.alloy](alloy-config.alloy) | Alloy 配置：OTLP 接收 → servicegraph/spanmetrics → Tempo/Prometheus/Loki |
| [beyla.yaml](beyla.yaml) | Beyla eBPF DaemonSet：ServiceAccount + RBAC + ConfigMap + DaemonSet |
| [grafana-values.yaml](grafana-values.yaml) | Grafana Helm values：NodePort 30300 + Tempo/Loki/Prometheus 数据源 |

### 文档与工具

| 文件 | 说明 |
|------|------|
| [production-deploy.md](production-deploy.md) | 完整生产环境部署指南（含架构图、验证步骤、故障排查） |
| [beyla.md](beyla.md) | Beyla eBPF 配置文档（内核要求、权限说明、与 OTel SDK 互补） |
| [deploy.sh](deploy.sh) | 一键部署脚本：MinIO → Tempo → Alloy → Beyla → Grafana |
| [test-apps.yaml](test-apps.yaml) | 测试 Demo 应用：Go (otel-demo) + Java (Spring Boot) + Python (Flask) |
| [alloy-config.sh](alloy-config.sh) | Alloy ConfigMap 创建 + 重启脚本（含 JSON 日志解析） |

## 一键部署

```bash
cd kubernetes/observability
bash deploy.sh
```

### 部署顺序

```
1. MinIO (S3 存储) → 2. Tempo (Trace 后端) → 3. Alloy (采集管道)
→ 4. Beyla (eBPF 埋点) → 5. Grafana (可视化)
```

### Grafana 访问

```
http://<任意节点IP>:30300
用户名: admin
密码: admin123
```

## 关联组件

| 组件 | 命名空间 | 文档 |
|------|---------|------|
| kube-prometheus-stack | `monitoring` | [../prometheus/install-steps.md](../prometheus/install-steps.md) |
| Prometheus standalone | `observability` | [../prometheus/README.md](../prometheus/README.md) |
| Loki | `monitoring` | [../loki/install-steps.md](../loki/install-steps.md) |

## 跨命名空间服务地址

部署在 `observability` 命名空间的组件通过集群 DNS 访问 `monitoring` 命名空间的服务：

| 服务 | DNS 地址 | 使用者 |
|------|---------|--------|
| Prometheus | `prometheus-kube-prometheus-prometheus.monitoring.svc:9090` | Alloy (remote_write) |
| Loki Gateway | `loki-gateway.monitoring.svc:80` | Alloy (loki.write) |
| Tempo Distributor | `tempo-distributor.observability:4317` | Alloy (OTLP export) |

## 应用接入

### 方式一：Beyla eBPF 零侵入（推荐）

Beyla 自动发现 `k8s_namespace: ""`（所有 namespace）下的 Service，无需修改应用代码或镜像。覆盖 HTTP/gRPC 调用链。

### 方式二：OTel SDK 手动埋点

保留代码中的 OTel SDK，发送到 Alloy：

```yaml
env:
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://alloy.observability:4318"
```

Beyla + OTel SDK 互补：Beyla 覆盖 HTTP/gRPC 协议层，SDK 覆盖 SQL/Redis/Kafka 等库调用。
