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
| [README.md](README.md) | 本文档 |
| [containerd-install.sh](containerd-install.sh) | 旧版(保留) |
| [containerd-offline-install.md](containerd-offline-install.md) | 离线步骤(含 crictl) |
| [add-nofile-limit.sh](add-nofile-limit.sh) | 句柄限制 |

---

## 一、安装

```bash
# 默认安装 containerd 2.1.3（2.x）
bash install.sh

# 如需安装 1.7 系列
CONTAINERD_VERSION=1.7.18 bash install.sh

# 如需指定其它 2.x 版本
CONTAINERD_VERSION=2.1.3 bash install.sh
```

> 当前脚本按主版本兼容 `1.x` 和 `2.x`（默认 `2.1.3`，1.x 示例 `1.7.18`）：`containerd config default` 生成的 `config.toml` 字段位置不同，脚本会按实际配置结构写入 `SystemdCgroup`、pause sandbox 镜像和 `certs.d`。

脚本做 8 件事:

| 步骤 | 做了什么 |
|---|---|
| 1 | 默认下载 `containerd-2.1.3-linux-amd64.tar.gz`，也支持 `CONTAINERD_VERSION=1.7.18` 或其它 2.x 版本 |
| 2 | 解压 `containerd` 到 `/usr/local`，解压 CNI 到 `/opt/cni/bin` |
| 3 | 创建 `/etc/systemd/system/containerd.service` |
| 4 | `containerd config default` 生成 `config.toml` |
| 5 | 兼容写入 `SystemdCgroup=true` / pause sandbox 镜像改阿里源 / `config_path` 开 certs.d |
| 6 | 写 `/etc/modules-load.d/k8s.conf`(`overlay + br_netfilter`) |
| 7 | 写 `/etc/sysctl.d/k8s.conf`(`ip_forward + bridge iptables`) |
| 8 | 安装 `runc` + `systemctl enable && restart` |

### config.toml 关键修改

脚本不要只做 `sed 's/SystemdCgroup = false/SystemdCgroup = true/'`：`containerd 2.x` 的默认配置可能已经不再生成 `SystemdCgroup` 这一行，必须按版本和实际 section 兜底插入。

| 版本 | CRI section | pause 字段 | cgroup 字段 |
|---|---|---|---|
| `1.7.18` | `[plugins."io.containerd.grpc.v1.cri"]` | `sandbox_image` | `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]` 下 `SystemdCgroup = true` |
| `2.x` | `[plugins."io.containerd.cri.v1.*]` | `pinned_images.sandbox` 或已有 sandbox 字段 | `[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]` 下 `SystemdCgroup = true` |

手动检查：

```bash
cp /usr/local/bin/containerd /usr/bin/containerd
containerd config default > /etc/containerd/config.toml

# 确认已生成
ls -l /etc/containerd/config.toml

# sandbox_image 走阿里 direct fallback
sed -i 's|registry.k8s.io/pause|registry.aliyuncs.com/google_containers/pause|' /etc/containerd/config.toml

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

## 二、镜像加速 — mirrors.sh 唯一入口

`install.sh` 只负责安装 containerd 并打开 `config_path = "/etc/containerd/certs.d"`；所有 `/etc/containerd/certs.d/<host>/hosts.toml` 统一由 `mirrors.sh` 写入。

```bash
bash install.sh
bash mirrors.sh
systemctl restart containerd
```

`mirrors.sh` 固定写 5 份 hosts.toml：

| `/etc/containerd/certs.d/<上游>/hosts.toml` | 指向 | 模式 |
|---|---|---|
| `docker.io` | `dockerhub.ihome.sxxpqp.top:8443` | Harbor pull-through |
| `registry.k8s.io` | `k8s.ihome.sxxpqp.top:8443` | Harbor pull-through |
| `quay.io` | `quay.ihome.sxxpqp.top:8443` | Harbor pull-through |
| `ghcr.io` | `ghcr.ihome.sxxpqp.top:8443` | Harbor pull-through |
| `registry.cn-hangzhou.aliyuncs.com` | `registry.cn-hangzhou.aliyuncs.com` | 阿里 ACR 直连 |

> 不要在业务 YAML / Dockerfile / 安装脚本里 sed 改 `image:` / `FROM`。保持 `docker.io` / `registry.k8s.io` / `quay.io` / `ghcr.io` 上游地址，由 containerd 根据 hosts.toml 自动走 mirror。

---

## 三、加速源映射

| 上游 | 代理地址 |
|---|---|
| `docker.io` | `dockerhub.ihome.sxxpqp.top:8443` |
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
systemctl --no-pager status containerd
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
| `crictl` `connection refused` | containerd 没跑 / sock 路径错 | `systemctl --no-pager status containerd` |
| `ImagePullBackOff` | registry 不通或 hosts.toml 没配 | `ctr -n k8s.io image pull` 手动测 |
| hosts.toml 不生效 | `config.toml` `config_path = ""` | 改成 `"/etc/containerd/certs.d"` + restart |
| `SystemdCgroup` 没对齐 | kubelet 用 cgroupfs | `config.toml` 里 `SystemdCgroup = true` |
| `sandbox_image` 拉不到 | `registry.k8s.io/pause` 国内不通 | 替换为 `registry.aliyuncs.com/google_containers/pause:3.9` |
