# OpenTelemetry Demo

OpenTelemetry **Demo 应用**（用于演示/测试），不含 Operator/Jaeger（已迁移到 LGTM + Beyla 栈）。

## 文件说明

| 文件 | 说明 |
|---|---|
| [opentelemetry-demo.yaml](opentelemetry-demo.yaml) | OpenTelemetry Demo 应用部署 |
| [replace-docker-image.sh](replace-docker-image.sh) | 替换 Docker 镜像脚本（离线环境/镜像仓库迁移） |

## 生产环境的真实可观测性栈

Demo 应用只是为了制造流量，**真实的 trace / log / metric 收集栈**在：

| 用途 | 目录 |
|---|---|
| 接入 + 采集 + 存储 + 可视化 | [../observability/](../observability/) （LGTM + Alloy + Beyla） |
| Prometheus 监控（CRD 方式） | [../prometheus/](../prometheus/) |
| Loki 日志 | [../loki/](../loki/) |

数据流：

```text
otel-demo 应用 ──OTLP──→ Alloy ─┬─ Trace → Tempo
                                ├─ Metrics → Prometheus (OTLP)
                                └─ Logs → Loki
                                (Beyla eBPF 自动 instrument 同样走 Alloy)
```

详细架构与部署见 [observability/README.md](../observability/README.md)。
