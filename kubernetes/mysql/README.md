# MySQL on K8s

K8s 部署 MySQL 服务（Deployment 模式，适用于测试/非高可用场景）。

> 裸机/VM 生产部署（InnoDB Cluster + Router + XtraBackup）见 [mysql/](../../mysql/)。

## 文件说明

| 文件 | 说明 |
|---|---|
| [mysql.yaml](mysql.yaml) | MySQL 5.7 Deployment 部署：mysql5.7-deployment 实例 |
| [backmysql.yaml](backmysql.yaml) | MySQL 备份 Deployment 部署 |
