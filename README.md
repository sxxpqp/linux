# Linux Ops Notes

Linux 运维知识库，涵盖容器编排、云原生、CI/CD、监控、网络等日常运维实践与笔记。每个目录都有对应的 [README.md](README.md) 说明文档。

## 目录结构

### 系统管理

| 目录 | 内容 | 状态 |
|---|---|---|
| [ansible/](ansible/README.md) | Ansible 自动化配置（Playbook、ad-hoc 命令） | 验证过 |
| [centos/](centos/README.md) | CentOS 系统管理（安全加固、LVM、内核升级、SSH 防护） | 验证过 |
| [ubuntu/](ubuntu/README.md) | Ubuntu 系统配置（APT 镜像源加速） | 验证过 |
| [shell-script/](shell-script/README.md) | Shell 脚本合集 | 验证过 |
| [git/](git/README.md) | Git 全局配置及代理设置 | 常用工具 |

### 容器与编排

| 目录 | 内容 | 状态 |
|---|---|---|
| [docker/](docker/README.md) | Docker 生态（安装、镜像构建、docker-compose 服务编排、Clash、Kind） | ✅ 生产验证 |
| [containerd/](containerd/README.md) | Containerd 运行时安装与配置（离线部署、K8s 集成） | 验证过 |

### 容器编排平台

| 目录 | 内容 | 状态 |
|---|---|---|
| [kubernetes/](kubernetes/README.md) | Kubernetes 核心（集群部署、网络、存储、监控、CI/CD） | ✅ 生产验证 |
| [k3s/](k3s/README.md) | K3s 轻量级 K8s（边缘计算、IoT） | 验证过 |
| [kubesphere/](kubesphere/README.md) | KubeSphere 容器平台（多集群管理、配置示例） | ✅ 生产验证 |
| [arm-k8s/](arm-k8s/README.md) | ARM 架构 K8s 集群（鲲鹏/飞腾） | 验证过 |

### 网络

| 目录 | 内容 | 状态 |
|---|---|---|
| [nginx/](nginx/README.md) | Nginx 配置（反向代理、SSL/TLS、HTTP-FLV 直播流） | ✅ 生产验证 |
| [dns/](dns/README.md) | BIND9 内网 DNS 服务搭建 | 验证过 |
| [frp/](frp/README.md) | frp 内网穿透（Docker & K8s 部署，TOML 配置） | ✅ 生产验证 |
| [nps/](nps/README.md) | nps 内网穿透 | ✅ 生产验证 |
| [clash/](clash/README.md) | Clash 代理客户端 | 验证过 |
| [istio/](istio/README.md) | Istio 服务网格（跨 Namespace 通信） | 验证过 |

### 存储

| 目录 | 内容 | 状态 |
|---|---|---|
| [minio/](minio/README.md) | MinIO 对象存储（Docker Compose、跨集群同步） | ✅ 生产验证 |
| [etcd/](etcd/README.md) | etcd 集群部署（Docker Compose、反向代理、备份） | ✅ 生产验证 |

### 数据库

| 目录 | 内容 | 状态 |
|---|---|---|
| [mysql/](mysql/README.md) | MySQL 运维（InnoDB Cluster、Router、备份、K8s CronJob） | ✅ 生产验证 |

### 监控

| 目录 | 内容 | 状态 |
|---|---|---|
| [prometheus/](prometheus/README.MD) | Prometheus & VictoriaMetrics 监控（部署指南、告警、Grafana） | ✅ 生产验证 |

### CI/CD

| 目录 | 内容 | 状态 |
|---|---|---|
| [devops/](devops/README.md) | CI/CD 流水线（Jenkins、Java/Node.js 项目部署、K8s Pod 模板） | ✅ 生产验证 |

### 工具

| 目录 | 内容 | 状态 |
|---|---|---|
| [k9s/](k9s/README.md) | K9s Kubernetes 终端管理工具 | 常用工具 |
| [go/](go/README.md) | Go 语言笔记（Channel 模式） | 学习笔记 |

> ✅ **生产验证** = 该模块的配置已在生产环境运行使用  
> **验证过** = 在测试/预发环境验证过  
> **学习笔记** = 个人学习记录，仅供参考

## 快速指引

| 场景 | 入口 |
|---|---|
| MySQL InnoDB 集群（生产推荐） | [mysql/mysql-config.md](mysql/mysql-config.md) |
| K8s 集群部署 | [kubernetes/README.md](kubernetes/README.md) |
| Prometheus 监控（VictoriaMetrics 生产推荐） | [prometheus/README.MD](prometheus/README.MD) |
| Jenkins CI/CD 流水线 | [devops/README.md](devops/README.md) |
| Docker 服务编排 | [docker/docker-compose/](docker/docker-compose/) |
| Nginx 反向代理 | [nginx/nginx.cnf](nginx/nginx.cnf) |
| frp 内网穿透 | [frp/README.md](frp/README.md) |
| MinIO 对象存储 | [minio/README.md](minio/README.md) |
