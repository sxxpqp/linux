# Kubeadm 离线安装 K8s — 二进制 + systemd 配置

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/kubeadm/offline-install-k8s.md
> 状态: 学习笔记

无 yum / apt 源场景下,手动下载 kubeadm/kubelet/kubectl 二进制 + 手写 systemd unit + `kubeadm init` 初始化集群。

## 一、下载二进制(可走 Nexus 代理)

```bash
RELEASE="$(curl -sSL https://dl.k8s.io/release/stable.txt)"
ARCH="amd64"

# 上游官方源(国内可能慢,改走 Nexus 见下方)
https://storage.googleapis.com/kubernetes-release/release/${RELEASE}/bin/linux/${ARCH}/kubeadm
https://storage.googleapis.com/kubernetes-release/release/${RELEASE}/bin/linux/${ARCH}/kubelet
https://storage.googleapis.com/kubernetes-release/release/${RELEASE}/bin/linux/${ARCH}/kubectl
```

下载完放到 `/usr/bin/` 并 `chmod +x`。

## 二、kubelet systemd unit

### 2.1 主 unit(`/lib/systemd/system/kubelet.service`)

```bash
cat >/lib/systemd/system/kubelet.service<<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/bin/kubelet

Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
```

### 2.2 kubeadm 专用 drop-in(`/etc/systemd/system/kubelet.service.d/10-kubeadm.conf`)

```bash
mkdir -p /etc/systemd/system/kubelet.service.d
cat >/etc/systemd/system/kubelet.service.d/10-kubeadm.conf<<EOF
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# 这个文件由 'kubeadm init' / 'kubeadm join' 在运行时生成,填 KUBELET_KUBEADM_ARGS
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
# 用户最后兜底的覆盖入口(建议优先用 .NodeRegistration.KubeletExtraArgs 而非这个)
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF
```

### 2.3 备用:从 Nexus 拉模板(替代手写)

```bash
# RELEASE_VERSION="v0.4.0"
curl -sSL "https://nexus.ihome.sxxpqp.top:8443/kubernetes/release/v0.4.0/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" \
  | tee /etc/systemd/system/kubelet.service

mkdir -p /etc/systemd/system/kubelet.service.d
curl -sSL "https://nexus.ihome.sxxpqp.top:8443/kubernetes/release/v0.4.0/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" \
  | tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
```

## 三、生成 kubeadm init 配置

```bash
kubeadm config print init-defaults > kubeadm-init.yaml
```

按下面模板改 IP / 主机名 / 镜像源 / 版本:

```yaml
apiVersion: kubeadm.k8s.io/v1beta3
bootstrapTokens:
  - groups:
      - system:bootstrappers:kubeadm:default-node-token
    token: abcdef.0123456789abcdef
    ttl: 24h0m0s
    usages:
      - signing
      - authentication
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 192.168.1.191      # ★ 改成本机 IP
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: IfNotPresent
  name: k8s-master01                    # ★ 改成本机 hostname
  taints: null
---
controlPlaneEndpoint: "192.168.1.190:8443"   # ★ 多 master HA 时配 LB / VIP
apiServer:
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta3
certificatesDir: /etc/kubernetes/pki
clusterName: kubernetes
imageRepository: registry.cn-hangzhou.aliyuncs.com/google_containers   # ★ 国内走阿里 ACR
controllerManager: {}
dns: {}
etcd:
  local:
    dataDir: /var/lib/etcd
kind: ClusterConfiguration
kubernetesVersion: 1.27.1               # ★ 跟你下载的二进制版本对齐
networking:
  dnsDomain: cluster.local
  serviceSubnet: 10.96.0.0/12
scheduler: {}
```

## 四、初始化集群(带 `--upload-certs` 给 HA 用)

```bash
kubeadm init --config kubeadm-init.yaml --upload-certs
```

`--upload-certs` 把证书上传到 kube-system 的 Secret,**其它 master 节点 join 时可以直接下载**,免去手动 scp。
