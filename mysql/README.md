# MySQL 运维

MySQL **裸机/VM 运维**配置，生产推荐 InnoDB Cluster（mysqlsh + Group Replication）。包含集群部署、Router 连接池、备份恢复。

> K8s 上部署 MySQL（Deployment + 备份 CronJob）见 [kubernetes/mysql/](../kubernetes/mysql/)。

## 文件说明

| 文件/目录 | 说明 | 状态 |
|---|---|---|
| [mysql-config.md](mysql-config.md) | MySQL 调优与集群配置：InnoDB Cluster 三节点部署（mysqlsh 管理）、MySQL Router 连接池调优、生产备份策略（util.dumpInstance + binlog） | ✅ 生产验证 |
| [my.conf](my.conf) | MySQL 配置文件模板：utf8 编码、docker 部署路径、bind-address |
| [mysqldump.sh](mysqldump.sh) | mysqldump 备份脚本：远程备份多个数据库、按日期命名、docker 内执行 |
| [delete_data.sh](delete_data.sh) | MySQL 数据清理脚本 |
| [init-config/](init-config/) | MySQL 初始化配置（Dockerfile + 初始化脚本） |
| [k8s-cronjob-backup/](k8s-cronjob-backup/) | K8s CronJob 自动备份：ConfigMap + CronJob + PVC，定时执行 mysqldump 备份 |
| [k8s-cronjob-host-cache/](k8s-cronjob-host-cache/) | K8s CronJob 清理 MySQL host cache |
| [xtrabackup/](xtrabackup/) | XtraBackup 物理备份脚本 |
