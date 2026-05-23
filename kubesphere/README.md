# KubeSphere 容器平台

KubeSphere 多集群管理、配置示例与运维。

## 文件说明

| 文件 | 说明 |
|---|---|
| [install.md](install.md) | KubeKey 部署指南：CentOS/Ubuntu 依赖安装（关闭防火墙、chrony 时间同步、关闭 SELinux、安装 socat/conntrack）、KubeKey 工具获取、all-in-one 快速安装、多节点集群创建（./kk create config）、节点增删、集群升级、kubectl 自动补全 |
| [config-sample.yaml](config-sample.yaml) | KubeKey Cluster CRD（kubekey.kubesphere.io/v1alpha2）：4 节点配置（etcd+control-plane 3 节点 + worker 1 节点）、KubeVIP 高可用（internalLoadbalancer: kube-vip）、Calico 网络、Docker 运行时、K8s v1.21.5、KubeSphere v3.3.2 ks-installer 详细配置（监控/日志/告警/DevOps/服务网格等组件开关） |
| [dconfig-sample.yaml](dconfig-sample.yaml) | 单节点 KubeKey 配置精简版：etcd+control-plane+worker 合一、DevOps 增强版配置 |
| [kubesphere-update-masterip.sh](kubesphere-update-masterip.sh) | Master 节点 IP 变更修复：备份并修改 /etc/etcd.env 中的旧 IP，批量替换 /etc/kubernetes 目录下所有配置文件中的 IP 地址 |
| [imagepull.sh](imagepull.sh) | 镜像策略批量修改：patch KubeSphere 系统组件（ks-apiserver/ks-console/ks-controller-manager/ks-installer/minio）的 imagePullPolicy 为 IfNotPresent；Docker tag 重命名（从阿里云 registry 到本地仓库）；rsync 分发镜像到各节点 |
| [tf.md](tf.md) | TensorFlow ROCm GPU 训练部署：Dockerfile 构建 rocm4.1-tf2.4-dev 镜像（依赖 opencv/lxml/tqdm/seaborn/yolov3_tf2）、K8s Deployment（NFS 挂载 /data/nfs/tf、amd.com/gpu:4、阿里云镜像仓库）、yolov3-tf2 模型下载与权重转换 |
| [nvidia-device-plugin.md](nvidia-device-plugin.md) | NVIDIA GPU 支持：nvidia-docker2 安装、daemon.json 配置 nvidia runtime、K8s nvidia-device-plugin 部署 |

## 多集群管理

### Host 集群配置要点

- 在 ks-installer 中设置 `clusterRole: host` 和 `proxyPublishAddress`
- 成员集群设置 `clusterRole: member` 并配置 host 集群的 `jwtSecret`
- 获取成员集群 kubeconfig: `kubectl get cluster [name] -o jsonpath='{.spec.connection.kubeconfig}' | base64 -d`

> **注意**：配置文件中的版本和 IP 地址仅供参考，请根据实际环境修改。
