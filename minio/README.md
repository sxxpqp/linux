# MinIO 对象存储

MinIO 对象存储 **Docker Compose 部署**，mc 客户端跨集群同步。

> K8s 内跨集群同步（mc mirror CronJob）见 [kubernetes/minio-sync/](../kubernetes/minio-sync/)。

## 文件说明

| 文件 | 说明 |
|---|---|
| [minio.md](minio.md) | mc 客户端跨集群同步配置：config host 添加两个 MinIO 端点，mc mirror 实现双向同步（--watch 实时监控、--overwrite 覆盖、--remove 删除同步） |
| [docker-compose.yaml](docker-compose.yaml) | MinIO 单节点部署：9000 API 端口、9001 Console 端口、Root 用户/密码配置、数据持久化卷 |
