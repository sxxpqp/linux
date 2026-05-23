# Shell 脚本合集

常用 Shell 脚本汇总。

## 文件说明

| 文件/目录 | 说明 |
|---|---|
| [init-mysql-minio/](init-mysql-minio/) | 项目初始化工具：Dockerfile（基于 mysql:5.7 + mc 客户端）、init.sh（自动创建 MySQL Schema 并导入 SQL 文件、mc 配置 MinIO 端点并 mirror 同步桶数据）、mc 二进制客户端 |

> 另有基础运维脚本在 [centos/](../centos/) 目录下（安全加固、内核升级、LVM 等）。
