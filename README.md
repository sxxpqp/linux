# Linux Ops Notes

Linux 运维知识库，涵盖容器编排、云原生、CI/CD、监控、网络等日常运维实践与笔记。

## 目录结构

| 目录 | 内容 |
|---|---|
| [ansible/](ansible/) | Ansible 自动化配置（CentOS 初始化、hello world 等） |
| [centos/](centos/) | CentOS 系统管理（安全加固、LVM、内核升级、SSH 防护等） |
| [containerd/](containerd/) | Containerd 运行时安装与配置 |
| [devops/](devops/) | CI/CD 流水线（Jenkins、Java/Node.js 项目部署、k8s pod 模板） |
| [dns/](dns/) | BIND9 内网 DNS 服务搭建 |
| [docker/](docker/) | Docker 生态（安装、镜像构建、docker-compose 服务编排、Containerlab、Kind、Clash） |
| [etcd/](etcd/) | etcd 集群部署与备份恢复 |
| [frp/](frp/) | frp 内网穿透（Docker & K8s 部署） |
| [git/](git/) | Git 配置 |
| [go/](go/) | Go 语言笔记（channel 模式等） |
| [istio/](istio/) | Istio 服务网格（多命名空间通信） |
| [k3s/](k3s/) | K3s 轻量级 K8s |
| [k9s/](k9s/) | K9s Kubernetes 终端管理工具 |
| [kubernetes/](kubernetes/) | Kubernetes 核心（RKE、RKE2、kubeadm、二进制部署、ingress-nginx、etcd、监控、存储、GPU 等） |
| [kubesphere/](kubesphere/) | KubeSphere 容器平台部署与配置 |
| [minio/](minio/) | MinIO 对象存储 |
| [mysql/](mysql/) | MySQL 运维（备份、xtrabackup、配置） |
| [nginx/](nginx/) | Nginx 配置（反向代理、SSL、HTTP-FLV 直播流） |
| [nps/](nps/) | nps 内网穿透 |
| [prometheus/](prometheus/) | Prometheus & Grafana 监控 |
| [shell-script/](shell-script/) | 常用 Shell 脚本合集 |
| [ubuntu/](ubuntu/) | Ubuntu 系统配置 |
| [arm-k8s/](arm-k8s/) | ARM 架构 K8s 集群 |
| [clash/](clash/) | Clash 代理客户端 |

## 快速指引

- **安装 Docker**: [docker-install.md](docker/docker-install.md)
- **K8s 集群部署**: [kubernetes/](kubernetes/) 下有多种方式（sealos、kubeadm、RKE、二进制）
- **Docker 服务编排**: [docker/docker-compose/](docker/docker-compose/) 包含 Redis、MySQL、Kafka、GitLab 等
- **Prometheus 监控**: [prometheus/](prometheus/)
- **CI/CD 流水线**: [devops/](devops/)
- **CentOS 安全加固**: [centos/centos-security-init.sh](centos/centos-security-init.sh)
