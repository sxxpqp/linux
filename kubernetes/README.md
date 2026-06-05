# Kubernetes

K8s 生产配置归档 — 集群部署、网络(Calico BPF/BGP/BGP-LB)、存储、中间件、监控、CI/CD 全栈。

> **找东西**：看下面的表定位到子目录 → 进子目录读 README

---

## 快速场景导航

| 场景 | 入口 |
|---|---|
| 新建集群 | [kubeadm/k8s-setup-menu.sh](kubeadm/k8s-setup-menu.sh) |
| **Calico CNI — BPF 模式(默认)** | [calico/onpremises/](calico/onpremises/) |
| **Calico CNI — BGP + 内置 LB(生产)** | [calico/bgp-lb/](calico/bgp-lb/) |
| 网络连通性验证 | [calico/test-connectivity.sh](calico/test-connectivity.sh) |
| 入口 — ingress-nginx DS+hostNetwork | [ingress-nginx/](ingress-nginx/) |
| 节点过载自动 cordon | [node-cordon-watcher/](node-cordon-watcher/) |
| LB — 裸金属 (Calico BGP-LB 替代) | [metallb/](metallb/) |
| 存储 — 动态 NFS | [csi-driver-nfs/](csi-driver-nfs/) |
| 存储 — 块存储 | [longhorn/](longhorn/) |
| 监控全栈 | [prometheus/](prometheus/) |
| 日志全栈 | [loki/](loki/) |
| 链路追踪 | [observability/](observability/) |
| 数据库统一 Operator | [kubeblocks/](kubeblocks/) |
| CI/CD | [jenkins/](jenkins/) / [tekton/](tekton/) / [argocd/](argocd/) |
| 证书自动管理 | [cert-manager/](cert-manager/) |
| etcd 备份恢复 | [etcd/](etcd/) |

---

## 目录索引

### 集群部署

| 目录 | 说明 | 状态 |
|---|---|---|
| [kubeadm/](kubeadm/) | kubeadm HA 集群、离线安装、菜单脚本 | ✅ |
| [minikube/](minikube/) | 本地单节点测试集群 | 验证过 |
| [learn/](learn/) | 二进制/RKE/RKE2 部署 + 内核参数/IPVS/Service 速查 | 验证过 |

### 网络

| 目录 | 说明 | 状态 |
|---|---|---|
| [calico/](calico/) | **Calico CNI 全模式** | |
| ├ [onpremises/](calico/onpremises/) | BPF + VXLAN(默认, 替换 kube-proxy) | ✅ |
| ├ [bgp/](calico/bgp/) | BGP node mesh(需 MetalLB 宣告 Service IP) | ✅ |
| ├ [bgp-lb/](calico/bgp-lb/) | **BGP + 内置 LB**(生产推荐, 免 MetalLB) | ✅ |
| └ [switch-to-bgp.sh](calico/switch-to-bgp.sh) | BPF→BGP 迁移脚本 | 参考 |
| [ingress-nginx/](ingress-nginx/) | ingress-nginx DS+hostNetwork(安装/卸载/验证) | ✅ |
| [metallb/](metallb/) | MetalLB(L2 + BGP) — 可被 Calico BGP-LB 替代 | ✅ |
| [kube-vip/](kube-vip/) | Kube-VIP LB | ✅ |
| [cross-ns-ingress-svc/](cross-ns-ingress-svc/) | 跨 Namespace Ingress | 验证过 |
| [kube-api-proxy/](kube-api-proxy/) | Nginx 反代 API Server | ✅ |
| [kubelet/](kubelet/) | kubelet 配置 + systemd | 验证过 |
| [traefik/](traefik/) | Traefik | 验证过 |
| [apisix/](apisix/) | APISIX 网关 | 验证过 |

### 存储

| 目录 | 说明 | 状态 |
|---|---|---|
| [csi-driver-nfs/](csi-driver-nfs/) | NFS CSI 动态 PVC | ✅ |
| [csi-driver-nfs-aliyun/](csi-driver-nfs-aliyun/) | 阿里云 NFS CSI | ✅ |
| [longhorn/](longhorn/) | Longhorn 分布式块存储 | ✅ |
| [minio-sync/](minio-sync/) | MinIO 跨集群同步 | ✅ |
| [rook/](rook/) | Rook Ceph | 验证过 |
| [glusterfs/](glusterfs/) | GlusterFS | 验证过 |
| [local-path/](local-path/) | local-path-provisioner(测试/开发) | 验证过 |
| [sc/](sc/) | OpenEBS StorageClass | 验证过 |
| [csi-longhorn/](csi-longhorn/) | Longhorn CSI | 验证过 |
| [csi-s3/](csi-s3/) | S3 CSI 驱动 | 验证过 |

### 中间件

| 目录 | 说明 | 状态 |
|---|---|---|
| [kubeblocks/](kubeblocks/) | KubeBlocks Operator(Redis/MySQL/PgSQL/Kafka 等 30+ 引擎) | ✅ |
| [redis/](redis/) | Redis Cluster | 验证过 |
| [mysql/](mysql/) | MySQL on K8s | 验证过 |
| [pgsql/](pgsql/) | PostgreSQL on K8s | 验证过 |
| [kafka/](kafka/) | Kafka(StatefulSet + Operator) | ✅ |
| [rocketmq/](rocketmq/) | RocketMQ | 验证过 |
| [es/](es/) | Elasticsearch(ECK Operator) | 验证过 |
| [turingcloud-elasticsearch/](turingcloud-elasticsearch/) | TuringCloud ES | ✅ |
| [doris/](doris/) | Doris CRD | 验证过 |
| [tdengine/](tdengine/) | TDengine 时序数据库 | 验证过 |
| [milvus/](milvus/) | Milvus 向量数据库 | 验证过 |
| [neo4j/](neo4j/) | Neo4j 图数据库 | 验证过 |

### 监控 / 日志 / 可观测性

| 目录 | 说明 | 状态 |
|---|---|---|
| [prometheus/](prometheus/) | kube-prometheus(Operator + Alertmanager + Grafana) | ✅ |
| [node-cordon-watcher/](node-cordon-watcher/) | 节点 CPU/内存 > 80% 自动 cordon, 恢复自动 uncordon | ✅ |
| [loki/](loki/) | Loki SimpleScalable(MinIO / S3) | 验证过 |
| [observability/](observability/) | LGTM + Beyla(eBPF 无侵入链路追踪) | 验证过 |
| [opentelemetry/](opentelemetry/) | OpenTelemetry Operator | 验证过 |

### CI/CD 与 DevOps

| 目录 | 说明 | 状态 |
|---|---|---|
| [jenkins/](jenkins/) | Jenkins on K8s(Docker-in-Docker) | ✅ |
| [tekton/](tekton/) | Tekton Pipeline + Dashboard | ✅ |
| [argocd/](argocd/) | ArgoCD GitOps | 验证过 |
| [harbor/](harbor/) | Harbor 镜像仓库 | ✅ |
| [gitlab/](gitlab/) | GitLab Helm | 验证过 |
| [srs/](srs/) | SRS 流媒体 | 验证过 |
| [sync-deployment/](sync-deployment/) | 跨集群应用同步 | ✅ |

### 安全 / 权限 / 证书

| 目录 | 说明 | 状态 |
|---|---|---|
| [cert-manager/](cert-manager/) | cert-manager 自动证书 | ✅ |
| [cert/](cert/) | K8s 证书手动轮换 | 验证过 |
| [rbac/](rbac/) | RBAC + kubeconfig | 验证过 |
| [secret/](secret/) | Secret 配置 | 验证过 |
| [cks/](cks/) | CKS 学习(NetworkPolicy) | 验证过 |
| [kube-device-plugin/](kube-device-plugin/) | NVIDIA GPU 设备插件 | ✅ |

### 工具 / 参考

| 目录 | 说明 | 状态 |
|---|---|---|
| [etcd/](etcd/) | etcd 备份恢复(CronJob) | ✅ |
| [helm/](helm/) | Helm 安装 | 验证过 |
| [lifecycle/](lifecycle/) | Pod 生命周期钩子 | 验证过 |
| [k8s/](k8s/) | 资源包归档(仅 YAML) | 归档 |

---

> ✅ = 生产验证  
> **验证过** = 测试/预发验证  
> **参考** = 迁移/切换类脚本, 非日常部署  
> **归档** = 历史文件, 不再维护
