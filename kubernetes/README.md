# Kubernetes 运维笔记

Kubernetes 集群部署、组件配置、存储、监控、CI/CD 等生产运维实践。

## 目录结构

### 集群部署

| 目录/文件 | 说明 | 状态 |
|---|---|---|
| [kubeadm/](kubeadm/) | kubeadm 部署高可用集群（离线安装、HA 配置、恢复） | ✅ 生产验证 |
| [binary-deploy-k8s.md](binary-deploy-k8s.md) | 二进制部署 K8s 集群（v1.23.6） | 验证过 |
| [v1.23.6-CentOS-binary-install.md](v1.23.6-CentOS-binary-install.md) | CentOS 二进制部署 K8s v1.23.6 | 验证过 |
| [v1.24.1-Ubuntu-binary-install-IPv6-IPv4](v1.24.1-Ubuntu-binary-install-IPv6-IPv4-Three-Masters-Two-Slaves.md) | Ubuntu 双栈二进制部署 K8s v1.24.1 | 验证过 |
| [v1.28.3-CentOS-binary-install-IPv6-IPv4](v1.28.3-CentOS-binary-install-IPv6-IPv4-Three-Masters-Two-Slaves-Offline.md) | CentOS 双栈离线二进制部署 K8s v1.28.3 | 验证过 |
| [rke-install-k8s.md](rke-install-k8s.md) | RKE 部署 K8s | 验证过 |
| [rke2-deploy-k8s.md](rke2-deploy-k8s.md) | RKE2 部署 K8s | ✅ 生产验证 |
| [minikube/](minikube/) | Minikube 本地测试集群安装 | 学习笔记 |
| [kubemini-install.md](kubemini-install.md) | kubemini 安装笔记 | 学习笔记 |

### 网络

| 目录/文件 | 说明 | 状态 |
|---|---|---|
| [calico/](calico/) | Calico CNI（v3.25 部署、BGP 切换） | ✅ 生产验证 |
| [ingress-nginx/](ingress-nginx/) | Ingress Nginx 配置（通用规则、rewrite、Prometheus 集成） | ✅ 生产验证 |
| [ingress/](ingress/) | Ingress 示例（demo、多路径路由） | 验证过 |
| [cross-ns-ingress-svc/](cross-ns-ingress-svc/) | 跨 Namespace Ingress 调用 Service 示例 | 验证过 |
| [kube-vip/](kube-vip/) | Kube-VIP 负载均衡器（阿里云 + 通用部署） | ✅ 生产验证 |
| [kube-api-proxy/](kube-api-proxy/) | K8s API 代理（nginx 反向代理 API Server） | ✅ 生产验证 |
| [kubelet/](kubelet/) | kubelet 配置（systemd service、kubeadm 配置） | 验证过 |
| [traefik/](traefik/) | Traefik Ingress Controller | 学习笔记 |
| [OpenELB.md](OpenELB.md) | OpenELB 负载均衡器 | 学习笔记 |

### 存储

| 目录/文件 | 说明 | 状态 |
|---|---|---|
| [csi-driver-nfs/](csi-driver-nfs/) | NFS CSI 驱动（K8s 动态挂载 NFS） | ✅ 生产验证 |
| [csi-driver-nfs-aliyun/](csi-driver-nfs-aliyun/) | 阿里云 NFS CSI 驱动 | ✅ 生产验证 |
| [csi-s3/](csi-s3/) | S3 CSI 驱动（对象存储挂载为 PV） | 验证过 |
| [csi-longhorn/](csi-longhorn/) | Longhorn CSI 配置 | 验证过 |
| [longhorn/](longhorn/) | Longhorn 存储（部署、前置依赖安装） | ✅ 生产验证 |
| [rook/](rook/) | Rook Ceph 存储集群 | 验证过 |
| [glusterfs/](glusterfs/) | GlusterFS 配置（topology） | 验证过 |
| [storageclass/](storageclass/) | StorageClass 配置（local-path） | 验证过 |
| [sc/](sc/) | 存储类补充（OpenEBS、默认 SC 配置） | 验证过 |
| [minio-sync/](minio-sync/) | MinIO 跨集群同步（mc mirror） | ✅ 生产验证 |

### 中间件部署

| 目录/文件 | 说明 | 状态 |
|---|---|---|
| [mysql/](mysql/) | K8s 部署 MySQL | 验证过 |
| [pgsql/](pgsql/) | K8s 部署 PostgreSQL | 验证过 |
| [redis-cluster/](redis-cluster/) | K8s 部署 Redis 集群 | 验证过 |
| [kafka/](kafka/) | Kafka 部署（StatefulSet + Operator） | ✅ 生产验证 |
| [rocketmq/](rocketmq/) | RocketMQ 部署 | 验证过 |
| [doris/](doris/) | Doris CRD 部署 | 验证过 |
| [milvus/](milvus/) | Milvus 向量数据库部署 | 学习笔记 |
| [neo4j/](neo4j/) | Neo4j 图数据库部署 | 学习笔记 |
| [tdengine/](tdengine/) | TDengine 时序数据库部署 | 验证过 |
| [es/](es/) | Elasticsearch 部署 | 验证过 |
| [turingcloud-elasticsearch/](turingcloud-elasticsearch/) | TuringCloud Elasticsearch 部署 | ✅ 生产验证 |

### 监控与日志

| 目录/文件 | 说明 | 状态 |
|---|---|---|
| [prometheus/](prometheus/) | Prometheus 生态（[安装指南](prometheus/deploy-guide.md)、Alertmanager、ServiceMonitor、Probe、Grafana Webhook） | ✅ 生产验证 |
| [loki/](loki/) | Loki 日志收集（Grafana 集成、S3 存储） | 验证过 |
| [opentelemetry/](opentelemetry/) | OpenTelemetry Operator + Demo 部署 | 学习笔记 |
| [srs/](srs/) | SRS 流媒体部署 | 验证过 |

### CI/CD 与 DevOps

| 目录/文件 | 说明 | 状态 |
|---|---|---|
| [jenkins/](jenkins/) | Jenkins on K8s（deploy、Docker-in-Docker、Java/Vue 示例项目） | ✅ 生产验证 |
| [tekton/](tekton/) | Tekton CI/CD（Pipeline、Dashboard、Git Clone） | ✅ 生产验证 |
| [argocd/](argocd/) | ArgoCD 部署配置 | 验证过 |
| [harbor/](harbor/) | Harbor 镜像仓库 Helm values | ✅ 生产验证 |
| [gitlab/](gitlab/) | GitLab Helm values | 验证过 |

### 管理与安全

| 目录/文件 | 说明 | 状态 |
|---|---|---|
| [cert-manager/](cert-manager/) | cert-manager 证书管理 | ✅ 生产验证 |
| [cert/](cert/) | K8s 证书轮换脚本 | 验证过 |
| [kube-device-plugin/](kube-device-plugin/) | GPU/NVIDIA 设备插件 | ✅ 生产验证 |
| [rbac/](rbac/) | RBAC 权限（kubeconfig 生成） | 验证过 |
| [secret/](secret/) | Secret 管理（Alertmanager 示例） | 验证过 |
| [cks/](cks/) | CKS 安全认证（NetworkPolicy） | 学习笔记 |
| [lifecycle/](lifecycle/) | Pod 生命周期钩子示例 | 学习笔记 |
| [helm/](helm/) | Helm 安装与使用 | 验证过 |
| [apisix/](apisix/) | Apache APISIX 网关 | 学习笔记 |
| [sync-deployment/](sync-deployment/) | 跨集群同步部署（rsync 方式） | ✅ 生产验证 |

### 工具

| 目录/文件 | 说明 | 状态 |
|---|---|---|
| [etcd/](etcd/) | etcd 备份恢复（脚本 + CronJob） | ✅ 生产验证 |
| [k8s/](k8s/) | 资源包归档（已清理二进制，保留 YAML） | 工具包 |

### 根文件

| 文件 | 说明 |
|---|---|
| [deployment-concepts.yaml](deployment-concepts.yaml) | Deployment 概念示例（滚动更新、回滚、探针） |
| [calico.yaml](calico.yaml) | Calico 完整部署 YAML |
| [daemonset-prod.yaml](daemonset-prod.yaml) | DaemonSet 生产示例 |
| [deploy.yaml](deploy.yaml) | 通用 Deployment 示例 |
| [service.yaml](service.yaml) | Service 示例 |
| [service-mechanism.md](service-mechanism.md) | Service 模式说明（ClusterIP/NodePort/LB/ExternalName） |
| [sa.yaml](sa.yaml) | ServiceAccount 示例 |
| [test.yaml](test.yaml) | 测试 Pod YAML |
| [pod-schedule.sh](pod-schedule.sh) | Pod 调度脚本 |
| [bug.md](bug.md) | K8s 常见问题记录 |
| [containerd.md](containerd.md) | Containerd 运行时 K8s 集成配置 |

## 快速参考

```bash
# 集群部署（新机器）
kubeadm/installk8s.sh                           # kubeadm 自动化安装
kubeadm/k8s-setup-menu.sh                       # 菜单式 K8s 部署

# 存储
csi-driver-nfs/installcsi-nfs.sh                # 安装 NFS CSI

# 证书管理
cert/k8s-cert-rotation.sh                       # 证书轮换

# etcd 备份
etcd/etcd-backup.sh                              # 全量备份
etcd/etcd-restore.sh                             # 恢复
```

## K8s 运维笔记

### 快速安装高可用集群（sealos）

```bash
sealos run labring/kubernetes-docker:v1.20.5-4.1.3 labring/helm:v3.8.2 \
  --masters 192.168.1.171,192.168.1.172,192.168.1.173 \
  --nodes 192.168.1.174 -p 1
sealos run labring/calico:v3.22.1-amd64
sealos run labring/openebs:v1.9.0
```

### 内核参数优化

```bash
# 网络性能
net.ipv4.ip_forward = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_fin_timeout = 30

# 文件打开数
fs.file-max = 1280000
fs.nr_open = 1280000

# conntrack
net.netfilter.nf_conntrack_max = 1000000
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 120
```

### 开启 IPVS 模式

```bash
cat > /etc/sysconfig/modules/ipvs.modules <<EOF
modprobe ip_vs
modprobe ip_vs_rr
modprobe ip_vs_wrr
modprobe ip_vs_sh
modprobe nf_conntrack
EOF
```
然后修改 kube-proxy 的 ConfigMap 中 `mode: ""` 为 `mode: "ipvs"`。

### 证书管理

```bash
# 查看
kubeadm certs check-expiration
# 更新
kubeadm certs renew all
# 重启组件
kubectl -n kube-system rollout restart deployment coredns
```

### Service 类型

| 类型 | 说明 |
|---|---|
| ClusterIP | 集群内访问（含 Headless: clusterIP: None） |
| NodePort | 宿主机端口暴露 |
| LoadBalancer | 云 LB 或 OpenELB/metallb |
| ExternalName | CNAME 到外部域名 |
| hostPort | Pod 使用宿主机端口 |
| hostNetwork | Pod 使用宿主机 IP |
