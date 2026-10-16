# KubeSphere 容器平台

KubeSphere 多集群管理、配置示例与运维。

## 文件说明

| 文件 | 说明 |
|---|---|
| [kind-3.4.1/Makefile](kind-3.4.1/Makefile) | 本地测试三步：`make kind` → `make mirrors` → `make ks-install`；`make deploy` 串行执行全部步骤 |
| [onpremises-3.4.1/Makefile](onpremises-3.4.1/Makefile) | 已有自建 K8s 安装：全部节点预检 → 备份并更新 containerd 镜像源 → 拉取验证 → 安装 ks-installer；默认只读预检 |
| [install.md](install.md) | KubeKey 部署指南：CentOS/Ubuntu 依赖安装（关闭防火墙、chrony 时间同步、关闭 SELinux、安装 socat/conntrack）、KubeKey 工具获取、all-in-one 快速安装、多节点集群创建（./kk create config）、节点增删、集群升级、kubectl 自动补全 |
| [config-sample.yaml](config-sample.yaml) | KubeKey Cluster CRD（kubekey.kubesphere.io/v1alpha2）：4 节点配置（etcd+control-plane 3 节点 + worker 1 节点）、KubeVIP 高可用（internalLoadbalancer: kube-vip）、Calico 网络、Docker 运行时、K8s v1.21.5、KubeSphere v3.3.2 ks-installer 详细配置（监控/日志/告警/DevOps/服务网格等组件开关） |
| [dconfig-sample.yaml](dconfig-sample.yaml) | 单节点 KubeKey 配置精简版：etcd+control-plane+worker 合一、DevOps 增强版配置 |
| [kubesphere-update-masterip.sh](kubesphere-update-masterip.sh) | Master 节点 IP 变更修复：备份并修改 /etc/etcd.env 中的旧 IP，批量替换 /etc/kubernetes 目录下所有配置文件中的 IP 地址 |
| [imagepull.sh](imagepull.sh) | 镜像策略批量修改：patch KubeSphere 系统组件（ks-apiserver/ks-console/ks-controller-manager/ks-installer/minio）的 imagePullPolicy 为 IfNotPresent；Docker tag 重命名（从阿里云 registry 到本地仓库）；rsync 分发镜像到各节点 |
| [tf.md](tf.md) | TensorFlow ROCm GPU 训练部署：Dockerfile 构建 rocm4.1-tf2.4-dev 镜像（依赖 opencv/lxml/tqdm/seaborn/yolov3_tf2）、K8s Deployment（NFS 挂载 /data/nfs/tf、amd.com/gpu:4、阿里云镜像仓库）、yolov3-tf2 模型下载与权重转换 |
| [nvidia-device-plugin.md](nvidia-device-plugin.md) | NVIDIA GPU 支持：nvidia-docker2 安装、daemon.json 配置 nvidia runtime、K8s nvidia-device-plugin 部署 |

## kind 测试环境：三步安装

```bash
cd kubernetes/kubesphere/kind-3.4.1
make kind        # 1. 安装配套 kind 工具并创建 Kubernetes 集群
make mirrors     # 2. 为全部 master/worker 设置镜像加速源
make ks-install  # 3. 安装 ks-installer 并等待 KubeSphere 就绪
# 或 make deploy，严格按上述顺序执行
```

第二步复用 `docker/containerd/mirrors.sh --kind-config`，先备份 kind 节点配置，移除旧 registry.mirrors 并启用 certs.d，然后写加速源、逐节点重启 containerd 并验证拉取；任何节点失败就停止。普通节点执行不带参数的 `mirrors.sh` 时行为不变。安装器镜像继续使用原有 `INSTALLER_SOURCE`，清单 image 保持上游名称。控制台 `http://127.0.0.1:30880`；`make status` / `make logs` 查看状态，`make login` 显示密码文件位置。原 `up` / `install` 等命令保留兼容，日常使用上面三个入口。

## 自建 Kubernetes 安装 KubeSphere 3.4.1

在完整仓库中执行，不新建 Kubernetes 集群。控制机需要 Bash、Python 3、kubectl、SSH；使用具备 cluster-admin 权限的 kubeconfig。

```bash
cd kubernetes/kubesphere/onpremises-3.4.1
cp nodes.example nodes.secret
# 编辑 nodes.secret：填写 kubectl get nodes 中的全部节点名和 SSH 地址（含 master）。
make plan CONTEXT=<实际context> KUBE_CONFIG=~/.kube/config
make install CONTEXT=<实际context> KUBE_CONFIG=~/.kube/config
make status CONTEXT=<实际context>
make logs CONTEXT=<实际context>
```

安装顺序固定为全部节点 SSH/CRI 预检、逐节点备份镜像源并运行仓库 `docker/containerd/mirrors.sh`、重启 containerd、拉取原始 `docker.io/kubesphere/ks-installer:v3.4.1`，全部成功后才提交安装清单。镜像源地址以中央脚本为准，不改 YAML 的 image。拉取失败即停止，不自动切换个人 Harbor 或阿里云镜像。

节点要求 Linux amd64、systemd、containerd，以及 root SSH 或免密 `sudo -n`；须事先启用 `/etc/containerd/certs.d` 的 `config_path`，此脚本不覆盖已有 containerd 主配置。镜像源备份保存在各节点 `/var/backups/ks341-mirrors.*`。不自动关闭防火墙或 SELinux，也不安装存储插件。

若上游安装器镜像已不可用，可显式传 `INSTALLER_SOURCE=<自行确认的ks-installer:v3.4.1镜像>`。脚本在每个节点拉取该源并建立上游名称的本地标签，清单仍保持上游 image；已有标签内容不一致时停止。不会自行猜测替代仓库，传入方需确认镜像版本及来源。

[官方兼容要求](https://www.kubesphere.io/docs/v3.4/installing-on-kubernetes/introduction/prerequisites/)为 Kubernetes 1.20～1.26，并配置默认 StorageClass；ARM 尚未完全支持，因此这个自建入口限制 amd64。脚本校验版本、节点 Ready、运行时和唯一默认存储类；容量、存储实际供卷和 kube-apiserver CSR 签名能力需由集群管理员保证。可用 `STORAGE_CLASS=<现有SC>` 指定组件存储，但仍需集群已有默认 SC。

复用 `kind-3.4.1/` 内的安装器和最小组件清单，仅在运行时注入实际存储类及初始密码；启用核心组件与内置监控，关闭 DevOps、日志、服务网格等可选组件，不依赖 kind、Traefik 或 Ingress。默认控制台 `http://<节点IP>:30880`，用户 `admin`；随机密码写入控制机 `~/.kube/ks341-<context>.secret`（0600），不打印或提交。可通过 `PASSWORD_FILE` 指定密码文件。`nodes.secret` 被仓库的 `*.secret` 忽略规则排除。

这是全新安装入口：检测到 `kubesphere-system` 已存在就停止，不覆盖已有安装或密码。若安装中途失败，使用 `make logs/status` 排查后按现有清单继续处理；不自动删除资源重装。完成条件为核心状态 enabled 和三个核心 Deployment 就绪，监控组件仍需另外查看 `kubesphere-monitoring-system`。

## 多集群管理

### Host 集群配置要点

- 在 ks-installer 中设置 `clusterRole: host` 和 `proxyPublishAddress`
- 成员集群设置 `clusterRole: member` 并配置 host 集群的 `jwtSecret`
- 获取成员集群 kubeconfig: `kubectl get cluster [name] -o jsonpath='{.spec.connection.kubeconfig}' | base64 -d`

> **注意**：配置文件中的版本和 IP 地址仅供参考，请根据实际环境修改。
