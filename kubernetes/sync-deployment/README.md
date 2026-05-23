# 跨集群同步部署

基于 rsync/shell 的 K8s 跨集群应用同步。

## 文件说明

| 文件 | 说明 |
|---|---|
| [sync-deployment-get.sh](sync-deployment-get.sh) | 获取源集群 Deployment 镜像列表：遍历命名空间下的 Deployment，提取容器镜像名称，用于对比同步 |
| [sync-update.sh](sync-update.sh) | 目标集群 Deployment 镜像更新脚本：根据源集群镜像列表，逐个更新目标集群 Deployment |
| [srs-push.yaml](srs-push.yaml) | SRS 流媒体服务推送同步配置 |
