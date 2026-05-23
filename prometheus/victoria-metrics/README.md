# VictoriaMetrics 生产部署

替代 Prometheus，兼容 PromQL 和 Grafana，存储效率高 10 倍。

## 架构

```text
┌──────────────┐      ┌──────────────────┐      ┌─────────┐
│ 被监控目标     │      │  VictoriaMetrics   │      │ Grafana │
│ (node/metrics)│ ──→  │  :8428            │ ←──  │ :3000   │
└──────────────┘      │  - 存储            │      └─────────┘
                      │  - 查询            │
                      │  - 数据去重         │
                      └──────────────────┘
```

## 方式一：替换 Prometheus（推荐）

VictoriaMetrics 单节点完全兼容 PromQL，可直接替代 Prometheus。

### 启动

```bash
docker-compose up -d
```

### 配置 Grafana 数据源

```
登录 Grafana → Configuration → Data Sources → Add data source → Prometheus
URL: http://victoria-metrics:8428
```

所有 Prometheus 仪表盘无需修改，直接可用。

## 方式二：Prometheus → VictoriaMetrics（迁移过渡）

如果已有 Prometheus，不想一次性切换，可以开启 remote write：

### Prometheus 配置

在现有 prometheus.yml 中追加：

```yaml
remote_write:
  - url: http://victoria-metrics:8428/api/v1/write
    queue_config:
      max_samples_per_send: 10000
      capacity: 50000
```

这样 Prometheus 继续工作，同时数据写入 VictoriaMetrics。切换 Grafana 数据源到 VictoriaMetrics，确认数据正常后关停 Prometheus。

## 验证

```bash
# 查询指标
curl http://127.0.0.1:8428/api/v1/query?query=up

# 健康检查
curl http://127.0.0.1:8428/health

# Web UI
# http://127.0.0.1:8428/   → vmui 查询界面
```

## vmagent（可选）

如果需要 Prometheus 的 pull 抓取功能，VictoriaMetrics 提供 vmagent 替代：

`docker-compose.vmagent.yml`

```yaml
version: "3"
services:
  vmagent:
    image: victoriametrics/vmagent:v1.108.0
    container_name: vmagent
    restart: always
    volumes:
      - ./prometheus-scrape.yml:/etc/prometheus-scrape.yml
    command:
      - "-remoteWrite.url=http://victoria-metrics:8428/api/v1/write"
      - "-promscrape.config=/etc/prometheus-scrape.yml"
```

`prometheus-scrape.yml` 与 Prometheus 的 scrape_config 格式完全一致。

## 关键参数

| 参数 | 说明 | 生产建议 |
|---|---|---|
| `-retentionPeriod` | 数据保留天数 | `60d` 或 `90d` |
| `-storageDataPath` | 数据存储路径 | SSD 磁盘，独立挂载 |
| `-memory.allowedPercent` | 内存使用上限 | 物理内存的 60% |
| `-search.maxQueryDuration` | 查询超时 | `30s` |
| `-dedup.minScrapeInterval` | 去重间隔 | `1ms`（默认） |

## 资源估算

| 指标量（每秒） | 磁盘/天 | 推荐配置 |
|---|---|---|
| 10 万 | ~2GB | 2C 4G |
| 50 万 | ~10GB | 4C 8G |
| 200 万 | ~40GB | 8C 16G + SSD |

## 与 Prometheus 对比

| | Prometheus | VictoriaMetrics |
|---|---|---|
| 存储效率 | 1x | 10x（数据压缩更好） |
| 查询性能 | 大数据量慢 | 快 10-20 倍 |
| 高可用 | Thanos 复杂 | 单节点够用，集群可选 |
| 兼容性 | — | 完全兼容 PromQL |
| 运维成本 | 中等 | 低（单二进制） |
