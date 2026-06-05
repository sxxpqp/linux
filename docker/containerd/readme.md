# Containerd — K8s 容器运行时完整配置

> 源: https://github.com/sxxpqp/linux/blob/main/docker/containerd/readme.md
> 状态: ✅ 生产验证

## TL;DR

```bash
bash install.sh   # 安装
bash mirrors.sh   # 加速源
crictl info       # 验证
```

## 架构位置

```
K8s Node
┌──────────────────────────────────────┐
│  kubelet ─→ containerd ─→ runc ─→ container │
│              (CRI)        (OCI)           │
│                                          │
│  配置:                                     │
│  /etc/containerd/config.toml   主配置        │
│  /etc/containerd/certs.d/*/   加速源        │
│  /etc/crictl.yaml             crictl 连接   │
└──────────────────────────────────────┘
```

## 文件

| 文件 | 说明 |
|---|---|
| [install.sh](install.sh) | 安装(二进制 + systemd + 内核参数 + config.toml) |
| [mirrors.sh](mirrors.sh) | 5 个上游加速源一键配置 |
| [readme.md](readme.md) | 本文档 |
| [containerd-install.sh](containerd-install.sh) | 旧版(保留) |
| [containerd-offline-install.md](containerd-offline-install.md) | 离线步骤(含 crictl) |
| [add-nofile-limit.sh](add-nofile-limit.sh) | 句柄限制 |

---

## 一、安装

```bash
bash install.sh
```

脚本做 8 件事:

| 步骤 | 做了什么 |
|---|---|
| 1 | 下载 `cri-containerd-cni-1.7.18` + `cni-plugins-v1.5.1` |
| 2 | 解压到 `/usr/local/bin` + `/opt/cni/bin` |
| 3 | 创建 `/etc/systemd/system/containerd.service` |
| 4 | `containerd config default` 生成 `config.toml` |
| 5 | sed: `SystemdCgroup=true` / `sandbox_image` 改代理 / `config_path` 开 certs.d |
| 6 | 写 `/etc/modules-load.d/k8s.conf`(`br_netfilter`) |
| 7 | 写 `/etc/sysctl.d/k8s.conf`(`ip_forward + bridge iptables`) |
| 8 | `systemctl enable --now` + 拉 runc |

### config.toml 关键修改

```bash
# cgroup 对齐 kubelet
sed -i 's|SystemdCgroup = false|SystemdCgroup = true|' /etc/containerd/config.toml

# sandbox_image 走代理
sed -i 's|registry.k8s.io/pause|k8s.ihome.sxxpqp.top:8443/pause|' /etc/containerd/config.toml

# 开 certs.d
sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml
```

### 内核参数(必须)

```bash
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay br_netfilter

cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
```

---

## 二、镜像加速 — copy 即用

### docker.io

```bash
mkdir -p /etc/containerd/certs.d/docker.io
cat > /etc/containerd/certs.d/docker.io/hosts.toml <<'EOF'
server = "https://registry-1.docker.io"
[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

### registry.k8s.io

```bash
mkdir -p /etc/containerd/certs.d/registry.k8s.io
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<'EOF'
server = "https://registry.k8s.io"
[host."https://k8s.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

### quay.io

```bash
mkdir -p /etc/containerd/certs.d/quay.io
cat > /etc/containerd/certs.d/quay.io/hosts.toml <<'EOF'
server = "https://quay.io"
[host."https://quay.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

### ghcr.io

```bash
mkdir -p /etc/containerd/certs.d/ghcr.io
cat > /etc/containerd/certs.d/ghcr.io/hosts.toml <<'EOF'
server = "https://ghcr.io"
[host."https://ghcr.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

### registry-1.docker.io(docker.io 别名)

```bash
mkdir -p /etc/containerd/certs.d/registry-1.docker.io
cat > /etc/containerd/certs.d/registry-1.docker.io/hosts.toml <<'EOF'
server = "https://registry-1.docker.io"
[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

### 阿里云 ACR(推送目标, 直连)

```bash
mkdir -p /etc/containerd/certs.d/registry.cn-hangzhou.aliyuncs.com
cat > /etc/containerd/certs.d/registry.cn-hangzhou.aliyuncs.com/hosts.toml <<'EOF'
server = "https://registry.cn-hangzhou.aliyuncs.com"
EOF
```

---

## 三、加速源映射

| 上游 | 代理地址 |
|---|---|
| `docker.io` | `dockerhub.ihome.sxxpqp.top:8443` |
| `registry-1.docker.io` | `dockerhub.ihome.sxxpqp.top:8443` |
| `registry.k8s.io` | `k8s.ihome.sxxpqp.top:8443` |
| `quay.io` | `quay.ihome.sxxpqp.top:8443` |
| `ghcr.io` | `ghcr.ihome.sxxpqp.top:8443` |
| 阿里云 ACR | `registry.cn-hangzhou.aliyuncs.com/sxxpqp/` (直连) |

| 自建服务 | 地址 | 用途 |
|---|---|---|
| Nexus | `nexus.ihome.sxxpqp.top:8443` | raw / helm / 二进制 |
| chfs | `chfs.sxxpqp.top:8443` | 文件分享 |
| MinIO | `ihome.sxxpqp.top:8443` | S3 |

---

## 四、crictl

```bash
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
```

---

## 五、验证

```bash
systemctl status containerd
crictl info | head -10
lsmod | grep -E 'overlay|br_netfilter'
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

# 验证加速源
ctr -n k8s.io image pull docker.io/library/nginx:alpine
ctr -n k8s.io image pull registry.k8s.io/pause:3.9
ctr -n k8s.io image pull quay.io/metallb/controller:v0.14.8
```

---

## 六、踩坑

| 现象 | 原因 | 修法 |
|---|---|---|
| `crictl` `connection refused` | containerd 没跑 / sock 路径错 | `systemctl status containerd` |
| `ImagePullBackOff` | registry 不通或 hosts.toml 没配 | `ctr -n k8s.io image pull` 手动测 |
| hosts.toml 不生效 | `config.toml` `config_path = ""` | 改成 `"/etc/containerd/certs.d"` + restart |
| `SystemdCgroup` 没对齐 | kubelet 用 cgroupfs | `config.toml` 里 `SystemdCgroup = true` |
| `sandbox_image` 拉不到 | `registry.k8s.io/pause` 国内不通 | 替换为 `k8s.ihome.sxxpqp.top:8443/pause:3.9` |
