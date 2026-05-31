# Prometheus & VictoriaMetrics 监控

Prometheus + Grafana **Docker/VM 部署**指南，以及 VictoriaMetrics 替代方案。

> K8s 集群内监控（kube-prometheus Operator + Alertmanager）见 [kubernetes/prometheus/](../kubernetes/prometheus/)。

## 文件说明

| 文件/目录 | 说明 |
|---|---|
| [Prometheus_Grafana_Installation.md](Prometheus_Grafana_Installation.md) | Prometheus + Grafana Docker 部署完整指南：Prometheus 配置与启动（prometheus.yml 静态采集目标配置、scrape_interval 45s、rule_files 告警规则）；Grafana 启动与插件安装；采集器部署（cadvisor 容器监控、mysqld-exporter、redis-exporter、node-exporter、nginx-exporter）；Grafana 仪表盘 ID 推荐（Linux/MySQL/Redis/Docker/JVM/GPU） |
| [victoria-metrics/](victoria-metrics/) | VictoriaMetrics 单节点替代 Prometheus：完全兼容 PromQL，存储效率高 10 倍。包含 docker-compose 部署（victoria-metrics + grafana）、vmagent 抓取配置、remote write 迁移方案、生产参数建议（retentionPeriod/storageDataPath/dedup） |

## 快速开始

### Prometheus Docker 部署

详见 [Prometheus_Grafana_Installation.md](Prometheus_Grafana_Installation.md)

### VictoriaMetrics 替代 Prometheus

详见 [victoria-metrics/](victoria-metrics/)
