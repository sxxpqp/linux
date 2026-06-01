# etcd 运维

K8s 集群内 etcd 备份恢复脚本与 CronJob 配置。

> Docker Compose 部署独立 etcd 集群见 [etcd/](../../etcd/)。

## 文件说明

| 文件/目录 | 说明 |
|---|---|
| [backupetcd.yaml](backupetcd.yaml) | etcd 备份 CronJob：定时备份到 PVC |
| [etcd-backup.sh](etcd-backup.sh) | etcd 全量备份脚本：ETCDCTL API v3，snapshot save |
| [etcd-restore.sh](etcd-restore.sh) | etcd 快照恢复脚本 |
| [instatletcdctl.sh](instatletcdctl.sh) | etcdctl 工具安装脚本 |
| [liset.md](liset.md) | etcd 日常运维命令：member list、endpoint health、snapshot save、snapshot status、snapshot restore 等 |
