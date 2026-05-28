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
| **Alloy** | DaemonSet | observability | 4317/4318 | OTLP 接收 + 日志采集（兜底） |
| **Beyla** | DaemonSet | observability | — | eBPF 零侵入自动埋点 |
| **Grafana** | Helm | observability | 30300(NodePort) | 统一可视化 |

> Prometheus（kube-prometheus-stack）在 `monitoring` 命名空间，Loki 在 `monitoring` 命名空间，跨命名空间通过 K8s Service DNS 互联。

## 数据流

```
Traces:  App/Beyla ──OTLP──→ Alloy ──→ Tempo Distributor (:4317) ──→ MinIO
                                  │
Tempo metrics-generator (service-graphs + span-metrics + local-blocks)
                                  │   ┌→ Prometheus pod-0 (:9090/api/v1/write)
                                  └───┤
                                      └→ Prometheus pod-1 (:9090/api/v1/write)   ← HA 双推

Metrics: App/Beyla ──OTLP──→ Alloy ──┬→ Prometheus pod-0 (:9090/api/v1/otlp)
                                     └→ Prometheus pod-1 (:9090/api/v1/otlp)     ← HA 双推

Logs:    App (OTel SDK) ──OTLP──→ Alloy ──→ Loki OTLP endpoint (:80/otlp)        ← 主路径
         App (非 OTel) ──stdout──→ /var/log/pods/ ──→ Alloy → Loki Gateway       ← 兜底
```

> - **RED 指标 + 拓扑**：由 Tempo metrics-generator 处理（`service-graphs` / `span-metrics` processor），不再由 Alloy 的 servicegraph/spanmetrics connectors 生成。
> - **TraceQL metrics**（`count_over_time()` / `rate()`）：由 metrics-generator 的 `local-blocks` processor 提供。
> - **HA 双推**：Prometheus 2 副本无共享存储，必须双推；详见下方 "跨命名空间服务地址"。

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
| [alloy-config.alloy](alloy-config.alloy) | Alloy 配置：OTLP 接收 → 三路分发（Traces→Tempo / Metrics→Prometheus OTLP / Logs→Loki OTLP）+ 文件日志兜底 |
| [beyla.yaml](beyla.yaml) | Beyla eBPF DaemonSet：ServiceAccount + RBAC + ConfigMap + DaemonSet |
| [grafana-values.yaml](grafana-values.yaml) | Grafana Helm values：NodePort 30300 + Tempo/Loki/Prometheus 数据源 |

### 文档与工具

| 文件 | 用途 |
|------|------|
| [production-deploy.md](production-deploy.md) | 完整生产环境部署指南（含架构图、验证步骤、故障排查） |
| [beyla.md](beyla.md) | Beyla eBPF 配置文档（内核要求、权限说明、与 OTel SDK 互补） |
| [test-apps.yaml](test-apps.yaml) | 测试 Demo 应用：Go (otel-demo) + Java (Spring Boot) + Python (Flask) |
| [deploy.sh](deploy.sh) | **一键部署**：MinIO → Tempo → Alloy → Beyla → Grafana（首次部署用这个） |
| [uninstall.sh](uninstall.sh) | **一键卸载**：默认保留 PVC/数据；加 `--purge` 完整清理；加 `--dry-run` 预演 |
| [alloy-config.sh](alloy-config.sh) | 只更新 Alloy（改了 `alloy-config.alloy` 后跑） |
| [tempo-update.sh](tempo-update.sh) | 只更新 Tempo（改了 `tempo-values.yaml` 后跑） |
| [grafana-deploy.sh](grafana-deploy.sh) | 只更新 Grafana（改了 `grafana-values.yaml`/datasource provisioning 后跑，会自动重启 pod 让 provisioning 生效） |
| [beyla-restart.sh](beyla-restart.sh) | 只重启 Beyla（升级 eBPF 程序或临时排障用） |

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
| Prometheus（统一 svc） | `prometheus-k8s.monitoring.svc:9090` | Grafana 查询 |
| Prometheus pod-0 | `prometheus-k8s-0.prometheus-operated.monitoring.svc:9090` | Alloy / Tempo 写入（HA 双推第 1 份） |
| Prometheus pod-1 | `prometheus-k8s-1.prometheus-operated.monitoring.svc:9090` | Alloy / Tempo 写入（HA 双推第 2 份） |
| Loki Gateway | `loki-gateway.monitoring.svc:80` | Alloy (OTLP `/otlp` + 文件日志 `/loki/api/v1/push`) |
| Tempo Distributor | `tempo-distributor.observability:4317` | Alloy (OTLP gRPC) |

> **HA 双推**：Prometheus 是 2 副本但没有共享存储，每个 pod 各自维护 TSDB。如果只往 Service ClusterIP 写，会被 round-robin 命中其中一个 pod，另一个 pod 完全没数据 —— Grafana 查询轮到那个空 pod 时面板就空。所以 Alloy 和 Tempo metrics-generator **必须显式双推到 `prometheus-operated` headless service 的每个 pod**。

## 前置依赖

本栈假设 `monitoring` 命名空间已部署 **kube-prometheus + Loki**。Prometheus CR (`prometheus-k8s`) 需要开启以下能力（[manifests/prometheus-prometheus.yaml](../prometheus/manifests/prometheus-prometheus.yaml)）：

```yaml
spec:
  enableFeatures:
    - exemplar-storage           # exemplar 跳 trace 必须
  enableRemoteWriteReceiver: true # 接 Tempo metrics-generator 推的服务图指标
  otlp:                          # 接 Alloy 推的 OTel 指标
    keepIdentifyingResourceAttributes: true
    translationStrategy: UnderscoreEscapingWithSuffixes
    promoteResourceAttributes:    # 把 OTel resource attribute 提升为 metric label
      - service.instance.id       # dashboard 22784 必需
      - service.name
      - service.namespace
      - deployment.environment.name
      - service.version
      - k8s.namespace.name
      - k8s.pod.name
      # ... 完整列表见 manifests/prometheus-prometheus.yaml
```

> **重要**：不要在 `additionalArgs` 里手动加 `web.enable-otlp-receiver` / `web.enable-remote-write-receiver`，prometheus-operator v0.78+ 会**自动管理**这两个 flag，重复声明会触发 `can't set arguments which are already managed by the operator` 错误，整个 reconcile 卡住、StatefulSet 不更新。

## 应用接入

### 方式一：Beyla eBPF 零侵入（推荐）

Beyla 自动发现 `k8s_namespace: ""`（所有 namespace）下的 Service，无需修改应用代码或镜像。覆盖 HTTP/gRPC 调用链。

> ⚠️ **Beyla 只生成 trace 和 metric，不会把 `trace_id` 注入到日志里**。要实现 Log → Trace 跳转，必须用方式二（OTel SDK）或方式三（手动注入 trace_id）。

### 方式二：OTel SDK 手动埋点

保留代码中的 OTel SDK，发送到 Alloy：

```yaml
env:
- name: NODE_IP
  valueFrom:
    fieldRef: { fieldPath: status.hostIP }
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://$(NODE_IP):4318"   # 走 hostPort 直连本节点的 Alloy（避免跨节点跳）
- name: OTEL_SERVICE_NAME
  value: "my-app"
- name: OTEL_RESOURCE_ATTRIBUTES
  # 注意是 deployment.environment.name（新版语义约定），不是旧的 deployment.environment
  value: "deployment.environment.name=production,service.namespace=default,service.version=1.0.0"
- name: OTEL_SEMCONV_STABILITY_OPT_IN
  value: "http"   # 用稳定版 HTTP 语义（http_server_request_duration_seconds 而非旧名）
```

Beyla + OTel SDK 互补：Beyla 覆盖 HTTP/gRPC 协议层，SDK 覆盖 SQL/Redis/Kafka 等库调用。

### 方式三：日志里手动写入 trace_id（实现 Log ↔ Trace 双向跳转必须）

**仅靠 Beyla 不够**——Beyla 给 metric 挂 exemplar、给 RPC 生成 trace，但**它不能修改你应用的日志输出**。如果应用日志里没有 `trace_id` 字段，那么：

- ❌ Loki 的 `derivedFields` regex 抓不到 `trace_id` → 日志旁不会出现 "View Trace" 按钮
- ❌ Tempo 的 `tracesToLogsV2` 跳过去后用 `|~ "<trace_id>"` 过滤日志也是空（日志里压根没这串字符）

要打通这条路，必须在**应用侧**把当前 span 的 `trace_id` 写进每条日志。三种典型做法：

#### 1) OTel SDK 自动注入（推荐，Java/Go/Python 等都有内置 logback/logrus/structlog 集成）

**Java + Logback** 示例：

```xml
<!-- logback-spring.xml -->
<configuration>
  <appender name="STDOUT" class="ch.qos.logback.core.ConsoleAppender">
    <encoder>
      <!-- %X{trace_id} %X{span_id} 由 OTel Java agent 自动注入 MDC -->
      <pattern>{"ts":"%d","level":"%p","logger":"%logger","msg":"%m","trace_id":"%X{trace_id}","span_id":"%X{span_id}"}%n</pattern>
    </encoder>
  </appender>
  <root level="INFO"><appender-ref ref="STDOUT"/></root>
</configuration>
```

启动命令带上 `-javaagent:/opentelemetry-javaagent.jar`，trace_id 会自动填到每条日志。

**Go + slog** 示例：

```go
import "go.opentelemetry.io/contrib/bridges/otelslog"
logger := otelslog.NewLogger("my-app")
// logger.InfoContext(ctx, "request handled") 会自动带 trace_id / span_id
```

#### 2) 框架级 middleware 手动注入

如果不用 OTel SDK，在 HTTP/RPC 中间件里手动从请求 header（`traceparent`）解出 trace_id，塞进 logger context。

#### 3) 应用日志直接打印 trace_id

不管什么方式，**最终日志里必须有这种字段**：

```json
{"ts":"...","level":"INFO","msg":"...","trace_id":"6a2d0abfb93ad433dbf78fec0ec2eff3","span_id":"8f3c2b1a0d9e4f7b"}
```

或 logfmt：

```
ts=2026-01-01T00:00:00Z level=INFO msg="..." trace_id=6a2d0abfb93ad433dbf78fec0ec2eff3 span_id=8f3c2b1a0d9e4f7b
```

Grafana 数据源的 Loki `derivedFields` 已配置三种格式的 regex（JSON / logfmt / camelCase `traceID=`），全都能识别。

## 验证与查询示例

部署完后用以下查询确认各跳转链路是否真的打通。**Grafana → Explore → 选对应数据源**。

### 1. Metric → Trace（exemplars 跳转）

**查询**（P99 延迟，Y 轴单位与 exemplar 同量纲，钻石点最容易看到）：

```promql
histogram_quantile(0.99,
  sum by(le) (
    rate(http_server_request_duration_seconds_bucket{service_name="<your-app>", service_namespace="<your-ns>"}[5m])
  )
)
```

操作步骤：

1. 时间范围选 **Last 1 hour**（5 分钟太短，exemplar 稀疏）
2. 可视化选 **Lines**（不要 Stacked bars，会遮住 exemplar）
3. 展开查询输入框下的 **Options** 面板，把 **Exemplars** toggle 打开
4. 重新 Run query
5. 曲线上会出现散落的彩色小圆点 → 鼠标悬停显示 `trace_id` → 点击跳 Tempo

> 为什么不用 `rate(_count[5m])`？rate 的 Y 轴是 req/s（值很小，0.01 量级），exemplar 的 Y 值是请求耗时（0.02~0.1 秒量级），两者错位，钻石点画在图表上沿外看不到。**用 histogram_quantile，Y 轴和 exemplar 都是秒，对齐**。

### 2. 命令行直接验证 exemplar 是否存在

不进 UI，直接问 Prometheus：

```bash
kubectl -n monitoring run -i --rm --restart=Never prom-test --image=curlimages/curl -- \
  sh -c 'NOW=$(date +%s); START=$((NOW - 3600)); curl -sG \
    "http://prometheus-k8s:9090/api/v1/query_exemplars" \
    --data-urlencode "query=http_server_request_duration_seconds_bucket{service_name=\"<your-app>\"}" \
    --data-urlencode "start=${START}" --data-urlencode "end=${NOW}"' | head -c 500
```

返回里有 `"exemplars":[{"labels":{"trace_id":"..."},...}]` 即 OK。如果是空 `[]`：Beyla / OTel SDK 没在发 exemplar，或 Prometheus 没开 `exemplar-storage` feature。

### 3. Trace → Logs 验证

Grafana Explore 选 **Tempo** → 用 TraceQL 搜你的 service：

```traceql
{ resource.service.name="<your-app>" }
```

随便点开一个 trace → 选一个 span → 右上角 **"Logs for this span"** 按钮。

预期生成的 Loki 查询：

```logql
{service_name="<your-app>", service_namespace="<your-ns>"} |~ "<trace_id>"
```

应该能查到这次请求的日志。如果**查询能跑但结果为空** → 应用没把 `trace_id` 写进日志，参考上面 **方式三**。

### 4. Log → Trace 验证

Explore 选 **Loki** → 查：

```logql
{service_name="<your-app>", service_namespace="<your-ns>"}
```

随便点开一条日志，右侧 detail 面板看 **Fields** 区域。如果日志内容里有 `trace_id` → 会出现一个名为 **TraceID (JSON/logfmt/OTel SDK)** 的字段 + 紫色 **"View Trace"** 按钮 → 点击跳 Tempo。

按钮**没出现** → 日志里没 trace_id（同上，需要应用侧加）。

### 5. Loki 标签兜底验证（不依赖应用日志格式）

不管应用日志是不是 JSON，Alloy 都会从 K8s 文件路径派生兜底标签：

```bash
kubectl -n monitoring run -i --rm --restart=Never loki-test --image=curlimages/curl -- \
  curl -sG "http://loki-gateway.monitoring/loki/api/v1/label/service_namespace/values"
```

返回 `{"status":"success","data":["test","uat","..."]}` 表示 Alloy 的 `stage.template` fallback 生效。如果返回 `[]` → Alloy 没跑或 ConfigMap 没更新到集群。

## 常用 Dashboard

直接通过 ID 在 Grafana 里导入：**Dashboards → New → Import → 输入 ID → Load → Datasource 选对应的数据源 → Import**。

| ID | 名称 | 数据源 | 用途 |
|---|---|---|---|
| **22784** | Lightweight APM for OpenTelemetry | Prometheus + Tempo | OTel/Beyla **核心 APM 面板**：RED 指标、服务拓扑、自带 exemplar 跳转。本栈主推 |
| **22748** | OpenTelemetry APM | Prometheus + Tempo | OTel 应用性能监控的另一个流行模板，可作为 22784 的备选/对比视角 |
| **8919** | 1 Node Exporter for Prometheus（中文 v3） | Prometheus | **节点资源监控**：CPU / 内存 / 磁盘 / 网络 / 负载，依赖 node-exporter |
| **13639** | Logs / App | Loki | **应用日志总览**：按 namespace/app/level 分布的日志量、错误率、热点 |
| **14969** | Kubernetes / Views / Namespaces | Prometheus | **K8s namespace 维度的资源视图**：pod、CPU、内存、网络，依赖 kube-state-metrics |

### 导入后要检查的事

1. **数据源 UID 对得上**：本栈固定 UID 是 `prometheus` / `loki` / `tempo`（见 [grafana-values.yaml](grafana-values.yaml)）。Dashboard 模板里用变量 `${DS_PROMETHEUS}` 这种就 OK，直接写死 UID 的要手动改。
2. **变量过滤器初值**：很多 dashboard 顶部有 `namespace` / `job` / `service` 下拉，新导入时可能选了空值面板空白。手动选一个有数据的。
3. **timeInterval 不匹配**：22784 / 22748 这种 OTel dashboard 用 `$__rate_interval`，本栈 datasource 配的 `timeInterval: 60s` 已经把它撑到 ≥4m，没问题。
4. **exemplar 没开**：导入后部分老模板的 panel 没默认开 exemplar，编辑面板 → Query Options → Exemplars 打开。22784 默认开了。

## 关键设计决策与会话纪要

为什么这套栈长这样：

### Prometheus（不是 Mimir）
- 单集群、小规模、HA 写入分裂可用双推解决 → Mimir 多出 11 个 pod 不划算
- 上 Mimir 的触发线：多集群联邦 / 百万级 active series / 多租户 / 月级 retention

### Tempo metrics-generator 启用三个 processor
| Processor | 提供能力 | Dashboard 22784 哪些面板依赖 |
|---|---|---|
| `service-graphs` | `traces_service_graph_*` | 服务拓扑图、节点延迟 |
| `span-metrics` | `traces_spanmetrics_*` | RED 派生指标 |
| `local-blocks` | TraceQL metrics（`rate()` / `count_over_time()` / `quantile_over_time()`） | 时间序列面板（Throughput / Latency Trend） |

缺 `local-blocks` 会导致 TraceQL metrics 查询失败，Grafana 表格组件抛 `TypeError __index`。

### Grafana 数据源 3 向关联
| 起点 → 终点 | 配置项 |
|---|---|
| Trace → Logs | Tempo `tracesToLogsV2`（V1 已废弃）+ 自定义 LogQL 按 trace_id 过滤 |
| Trace → Metrics | Tempo `tracesToMetrics`，4 条预置查询用 OTel 原生指标 |
| Logs → Traces | Loki `derivedFields`，3 个 regex 覆盖 JSON / logfmt / OTel SDK 注入三种格式 |
| Metrics → Traces | Prometheus `exemplarTraceIdDestinations`，label 名 `trace_id`（**不是** `traceID`） |

`tempo-distributed` chart **1.61.x 的 overrides key 是顶层 `overrides:`**，不是更老版本的 `global_overrides`，写错会渲染出 `overrides: null` 导致 metrics-generator 不启用任何 processor。

### Alloy 双推到每个 Prometheus 副本
```
otelcol.processor.batch "metrics" {
  output {
    metrics = [
      otelcol.exporter.otlphttp.prometheus_0.input,  # → pod-0
      otelcol.exporter.otlphttp.prometheus_1.input,  # → pod-1
    ]
  }
}
```
对应 Tempo metrics-generator 的 `remote_write` 也要列两条 URL，分别指向 `prometheus-k8s-0` 和 `prometheus-k8s-1`。

### OTel 指标命名翻译
Prometheus OTLP receiver 默认 `translationStrategy: UnderscoreEscapingWithSuffixes`：
- OTel Sum / Counter → 加 `_total` 后缀（`my_counter` → `my_counter_total`）
- OTel Histogram → 拆 `_bucket` / `_count` / `_sum`
- 测试 OTel payload 时如果查不到要带后缀查

### Grafana datasource `timeInterval: 60s`
OTLP 推送间隔是 60s（Beyla/OTel SDK 默认）。Grafana 的 `$__rate_interval` 若小于推送间隔，`rate()` 会返回空 —— dashboard 末尾出现"空洞"全因为此。

## 日常运维 cheat sheet

| 改了什么 | 跑什么 | 注意 |
|---|---|---|
| `alloy-config.alloy` | `bash alloy-config.sh` | DaemonSet 滚动重启，老日志已写入的标签**不会回填**，等几分钟看新日志 |
| `tempo-values.yaml` | `bash tempo-update.sh` | metrics-generator processor 改了要等 30s 才生效 |
| `grafana-values.yaml` | `bash grafana-deploy.sh` | **datasource provisioning 不会热加载**，脚本里已自动 `rollout restart` |
| `prometheus-prometheus.yaml`（外部仓库） | `kubectl apply -f ../prometheus/manifests/prometheus-prometheus.yaml` | 改 `spec.otlp` 等字段需要 operator ≥ v0.78 + CRD 同步升级 |
| `beyla.yaml`（ConfigMap 部分） | `bash beyla-restart.sh` | eBPF 重新挂载，业务流量短暂可能漏采几秒 |

### 配置改了不生效，先排查这三步

1. **ConfigMap/Secret 真的更新到集群了吗**
   ```bash
   kubectl -n observability get cm alloy-config -o jsonpath='{.data.config\.alloy}' | grep -A 2 "你的改动关键字"
   ```
2. **Pod 真的重启读取新配置了吗**（很多组件不监听 ConfigMap 变化）
   ```bash
   kubectl -n observability get pod -l app=alloy -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.startTime}{"\n"}{end}'
   ```
3. **新数据真的进来了吗**（老数据不会回填新标签/字段）—— 用上方"验证与查询示例"里的 curl 命令直接问数据源。

