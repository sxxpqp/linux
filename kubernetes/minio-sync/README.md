# MinIO 跨集群同步

K8s 内基于 mc mirror 的 MinIO 跨集群同步（CronJob 定时执行）。

> Docker Compose 部署 MinIO 本体见 [minio/](../../minio/)。

## 文件说明

| 文件 | 说明 |
|---|---|
| [mc-mirror.yaml](mc-mirror.yaml) | MinIO 跨集群同步 CronJob/Deployment：turingcloud-mc 服务，定时执行 mc mirror 同步操作 |
