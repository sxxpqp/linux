# MinIO 跨集群同步

基于 mc mirror 的 MinIO 跨集群同步，支持从源集群自动同步到目标集群。

## 文件说明

| 文件 | 说明 |
|---|---|
| [mc-mirror.yaml](mc-mirror.yaml) | MinIO 跨集群同步 CronJob/Deployment：turingcloud-mc 服务，定时执行 mc mirror 同步操作 |
