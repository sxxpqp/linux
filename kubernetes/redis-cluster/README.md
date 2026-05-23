# Redis 集群

K8s 部署 Redis 集群及监控。

## 文件说明

| 文件 | 说明 |
|---|---|
| [redis.yaml](redis.yaml) | Redis Deployment 部署：redis 实例 |
| [ServiceMonitor.yaml](ServiceMonitor.yaml) | Redis 指标采集 ServiceMonitor：监控 Redis 暴露的 metrics 端口 |
