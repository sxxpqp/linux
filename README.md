# Linux Ops Notes

Linux 运维知识库，涵盖容器编排、云原生、CI/CD、监控、网络等日常运维实践与笔记。

## 目录结构

| 目录 | 内容 | 状态 |
|---|---|---|
| [ansible/](ansible/) | Ansible 自动化配置 | 验证过 |
| [centos/](centos/) | CentOS 系统管理（安全加固、LVM、内核升级、SSH 防护等） | 验证过 |
| [containerd/](containerd/) | Containerd 运行时安装与配置 | 验证过 |
| [devops/](devops/) | CI/CD 流水线（Jenkins、Java/Node.js 项目部署、k8s pod 模板） | ✅ 生产验证 |
| [dns/](dns/) | BIND9 内网 DNS 服务搭建 | 验证过 |
| [docker/](docker/) | Docker 生态（安装、镜像构建、docker-compose 服务编排） | ✅ 生产验证 |
| [etcd/](etcd/) | etcd 集群部署与备份恢复 | ✅ 生产验证 |
| [frp/](frp/) | frp 内网穿透（Docker & K8s 部署） | ✅ 生产验证 |
| [git/](git/) | Git 配置 | 验证过 |
| [go/](go/) | Go 语言笔记 | 学习笔记 |
| [istio/](istio/) | Istio 服务网格 | 验证过 |
| [k3s/](k3s/) | K3s 轻量级 K8s | 验证过 |
| [k9s/](k9s/) | K9s Kubernetes 终端管理工具 | 常用工具 |
| [kubernetes/](kubernetes/) | Kubernetes 核心（RKE、RKE2、kubeadm、ingress-nginx、etcd 等） | ✅ 生产验证 |
| [kubesphere/](kubesphere/) | KubeSphere 容器平台 | ✅ 生产验证 |
| [minio/](minio/) | MinIO 对象存储 | ✅ 生产验证 |
| [mysql/](mysql/) | MySQL 运维（InnoDB Cluster、主从、备份） | ✅ 生产验证 |
| [nginx/](nginx/) | Nginx 配置（反向代理、SSL、HTTP-FLV 直播流） | ✅ 生产验证 |
| [nps/](nps/) | nps 内网穿透 | ✅ 生产验证 |
| [prometheus/](prometheus/) | Prometheus & Grafana 监控 | ✅ 生产验证 |
| [shell-script/](shell-script/) | 常用 Shell 脚本合集 | 验证过 |
| [ubuntu/](ubuntu/) | Ubuntu 系统配置 | 验证过 |
| [arm-k8s/](arm-k8s/) | ARM 架构 K8s 集群 | 验证过 |
| [clash/](clash/) | Clash 代理客户端 | 验证过 |

> ✅ **生产验证** = 该模块的配置已在生产环境运行使用  
> **验证过** = 在测试/预发环境验证过

## 快速指引

- **MySQL InnoDB 集群（生产推荐）**: [mysql/mysql-config.md](mysql/mysql-config.md) — 基于 mysqlsh + Group Replication，含 Router 连接池与调优
- **安装 Docker**: [docker/docker-install.md](docker/docker-install.md)
- **K8s 集群部署**: [kubernetes/](kubernetes/) 下有多种方式（sealos、kubeadm、RKE、二进制）
- **Docker 服务编排**: [docker/docker-compose/](docker/docker-compose/) 包含 Redis、MySQL、Kafka、GitLab 等
- **Prometheus 监控**: [prometheus/](prometheus/)
- **CI/CD 流水线**: [devops/](devops/)
- **Nginx 反向代理**: [nginx/nginx.cnf](nginx/nginx.cnf)
- **frp 内网穿透**: [frp/docker/frps.md](frp/docker/frps.md)
