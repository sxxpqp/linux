# Kubernetes

K8s 生产配置归档——集群部署、网络、存储、中间件、监控、CI/CD 全栈。

> **找东西的顺序**：
> 1. 先看下面的表，定位到对应子目录
> 2. 进子目录读它自己的 README
> 3. `learn/README.md` 是详细运维笔记汇总（内核参数、证书、Service 类型速查等），不是文件索引

---

## 快速场景导航

| 场景 | 入口 |
|---|---|
| 新建集群（推荐） | [kubeadm/k8s-setup-menu.sh](kubeadm/k8s-setup-menu.sh) |
| 存储 — 动态 NFS | [csi-driver-nfs/](csi-driver-nfs/) |
| 存储 — 块存储 | [longhorn/](longhorn/) |
| LB — 裸金属 | [metallb/](metallb/) |
| LB — 高可用 VIP | [kube-vip/](kube-vip/) |
| Ingress 反代 | [ingress-nginx/](ingress-nginx/) |
| 监控全栈 | [prometheus/](prometheus/) |
| 日志全栈 | [loki/](loki/) |
| 链路追踪 + 可观测 | [observability/](observability/) |
| 数据库统一 Operator | [kubeblocks/](kubeblocks/) |
| etcd 备份恢复 | [etcd/](etcd/) |
| 证书轮换 | [cert/](cert/) |
| CI/CD 流水线 | [jenkins/](jenkins/) / [tekton/](tekton/) |
| 镜像仓库（Harbor on K8s） | [harbor/](harbor/) |

---

## 目录索引

### 集群部署

| 目录 | 说明 | 状态 |
|---|---|---|
| [kubeadm/](kubeadm/) | kubeadm HA 集群、离线安装、菜单脚本、VIP 恢复 | ✅ 生产验证 |
| [minikube/](minikube/) | 本地单节点测试集群 | 学习笔记 |
| [learn/](learn/) | 二进制/RKE/RKE2 部署文档 + 运维笔记（内核参数、IPVS、Service 速查） | 验证过 |

### 网络

| 目录 | 说明 | 状态 |
|---|---|---|
| [calico/](calico/) | Calico CNI（v3.25、BGP 切换） | ✅ 生产验证 |
| [ingress-nginx/](ingress-nginx/) | Ingress Nginx（通用规则、rewrite、Prometheus 集成） | ✅ 生产验证 |
| [ingress/](ingress/) | Ingress 示例（demo、多路径路由） | 验证过 |
| [cross-ns-ingress-svc/](cross-ns-ingress-svc/) | 跨 Namespace Ingress 访问 Service | 验证过 |
| [kube-vip/](kube-vip/) | Kube-VIP 虚 IP（阿里云 + 通用） | ✅ 生产验证 |
| [metallb/](metallb/) | MetalLB LoadBalancer（BGP / L2 模式） | ✅ 生产验证 |
| [kube-api-proxy/](kube-api-proxy/) | Nginx 反代 API Server | ✅ 生产验证 |
| [kubelet/](kubelet/) | kubelet 配置文件与 systemd service | 验证过 |
| [traefik/](traefik/) | Traefik Ingress Controller | 学习笔记 |
| [apisix/](apisix/) | Apache APISIX 网关 | 学习笔记 |

### 存储

| 目录 | 说明 | 状态 |
|---|---|---|
| [csi-driver-nfs/](csi-driver-nfs/) | NFS CSI 驱动（K8s 动态 PVC） | ✅ 生产验证 |
| [csi-driver-nfs-aliyun/](csi-driver-nfs-aliyun/) | 阿里云 NFS CSI | ✅ 生产验证 |
| [longhorn/](longhorn/) | Longhorn 分布式块存储（部署 + 前置检查） | ✅ 生产验证 |
| [csi-longhorn/](csi-longhorn/) | Longhorn CSI 驱动配置 | 验证过 |
| [csi-s3/](csi-s3/) | S3 对象存储 CSI 驱动 | 验证过 |
| [rook/](rook/) | Rook Ceph 存储集群 | 验证过 |
| [glusterfs/](glusterfs/) | GlusterFS 分布式存储 | 验证过 |
| [storageclass/](storageclass/) | StorageClass（local-path） | 验证过 |
| [sc/](sc/) | OpenEBS 存储类 | 验证过 |
| [minio-sync/](minio-sync/) | MinIO 跨集群同步（mc mirror CronJob） | ✅ 生产验证 |

### 中间件

| 目录 | 说明 | 状态 |
|---|---|---|
| [kubeblocks/](kubeblocks/) | KubeBlocks Operator（Redis / MySQL / PgSQL / Kafka 等 30+ 引擎统一管理） | ✅ 生产验证 |
| [redis/](redis/) | Redis Cluster（StatefulSet，独立于 KubeBlocks） | 验证过 |
| [mysql/](mysql/) | MySQL on K8s | 验证过 |
| [pgsql/](pgsql/) | PostgreSQL on K8s | 验证过 |
| [kafka/](kafka/) | Kafka（StatefulSet + Operator） | ✅ 生产验证 |
| [rocketmq/](rocketmq/) | RocketMQ | 验证过 |
| [es/](es/) | Elasticsearch（ECK Operator） | 验证过 |
| [turingcloud-elasticsearch/](turingcloud-elasticsearch/) | TuringCloud Elasticsearch StatefulSet | ✅ 生产验证 |
| [doris/](doris/) | Doris CRD 部署 | 验证过 |
| [tdengine/](tdengine/) | TDengine 时序数据库 | 验证过 |
| [milvus/](milvus/) | Milvus 向量数据库 | 学习笔记 |
| [neo4j/](neo4j/) | Neo4j 图数据库 | 学习笔记 |

### 监控 / 日志 / 可观测性

| 目录 | 说明 | 状态 |
|---|---|---|
| [prometheus/](prometheus/) | kube-prometheus（Operator CRD + Alertmanager + PrometheusAlert + Grafana Webhook） | ✅ 生产验证 |
| [loki/](loki/) | Loki SimpleScalable（MinIO / 外部 S3 两种模式） | 验证过 |
| [observability/](observability/) | LGTM + Beyla 全栈（Loki + Tempo + Mimir + Grafana + Alloy，eBPF 无侵入链路追踪） | 验证过 |
| [opentelemetry/](opentelemetry/) | OpenTelemetry Operator + Demo | 学习笔记 |

### CI/CD 与 DevOps

| 目录 | 说明 | 状态 |
|---|---|---|
| [jenkins/](jenkins/) | Jenkins on K8s（deploy、Docker-in-Docker） | ✅ 生产验证 |
| [tekton/](tekton/) | Tekton Pipeline + Dashboard | ✅ 生产验证 |
| [argocd/](argocd/) | ArgoCD GitOps 部署 | 验证过 |
| [harbor/](harbor/) | Harbor 镜像仓库 Helm values（旧业务 `harbor.iot.store:8085`） | ✅ 生产验证 |
| [gitlab/](gitlab/) | GitLab Helm values | 验证过 |
| [srs/](srs/) | SRS 流媒体服务器 | 验证过 |
| [sync-deployment/](sync-deployment/) | 跨集群应用同步（rsync + shell） | ✅ 生产验证 |

### 安全 / 权限 / 证书

| 目录 | 说明 | 状态 |
|---|---|---|
| [cert-manager/](cert-manager/) | cert-manager 自动证书 | ✅ 生产验证 |
| [cert/](cert/) | K8s 证书手动轮换脚本 | 验证过 |
| [rbac/](rbac/) | RBAC + kubeconfig 生成 | 验证过 |
| [secret/](secret/) | Secret 配置示例 | 验证过 |
| [cks/](cks/) | CKS 认证学习（NetworkPolicy） | 学习笔记 |
| [kube-device-plugin/](kube-device-plugin/) | NVIDIA GPU 设备插件 | ✅ 生产验证 |

### 工具 / 参考

| 目录 | 说明 | 状态 |
|---|---|---|
| [etcd/](etcd/) | etcd 备份恢复（脚本 + K8s CronJob） | ✅ 生产验证 |
| [helm/](helm/) | Helm 安装 | 验证过 |
| [lifecycle/](lifecycle/) | Pod 生命周期钩子示例 | 学习笔记 |
| [k8s/](k8s/) | 资源包归档（仅 YAML，已清理二进制） | 工具包 |

---

> ✅ **生产验证** = 在生产环境跑过  
> **验证过** = 测试 / 预发环境验证过  
> **学习笔记** = 个人学习记录，仅供参考
