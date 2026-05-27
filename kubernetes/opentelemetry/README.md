# OpenTelemetry

OpenTelemetry Operator + Demo 部署。

## 文件说明

| 文件 | 说明 |
|---|---|
| [opentelemetry-operator.yaml](opentelemetry-operator.yaml) | OpenTelemetry Operator 部署：Namespace、CRD、Operator Deployment |
| [opentelemetry-demo.yaml](opentelemetry-demo.yaml) | OpenTelemetry Demo 应用部署 |
| [replace-docker-image.sh](replace-docker-image.sh) | 替换 Docker 镜像脚本（用于离线环境或镜像仓库迁移） |

---

## 升级方案：Alloy + Tempo

当前使用 Jaeger + DaemonSet Collector 是测试方案。生产环境推荐替换为：

| 组件 | 旧方案 | 新方案 | 配置目录 |
|---|---|---|---|
| Trace 存储 | Jaeger all-in-one | Tempo（分布式、S3 持久化） | [../tempo/](../tempo/) |
| 数据接入 | OTel Collector DaemonSet | Grafana Alloy（内置 servicegraph/spanmetrics） | [../alloy/](../alloy/) |
| 指标存储 | — | Mimir（接收 RED + 拓扑指标） | [../prometheus/](../prometheus/) |

Alloy 流水线：

```text
Go 应用 ──OTLP──→ Alloy ─┬─ 原始 Trace → Tempo
                         ├─ 拓扑指标 → Mimir (Prometheus)
                         └─ RED 指标 → Mimir (Prometheus)
```

> [Alloy 安装指南](../alloy/install-steps.md) | [Tempo 安装指南](../tempo/install-steps.md)
