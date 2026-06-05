# Containerd 安装与配置

## 加速源 — 直接复制执行

> 前置: config.toml 必须开 `config_path`。每段复制到终端跑。

```bash
# 前置(没开的话, install.sh 已自动设)
sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml
```

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

### registry-1.docker.io (docker.io 别名)

```bash
mkdir -p /etc/containerd/certs.d/registry-1.docker.io
cat > /etc/containerd/certs.d/registry-1.docker.io/hosts.toml <<'EOF'
server = "https://registry-1.docker.io"
[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

### 阿里云 ACR (直连, 推送目标)

```bash
mkdir -p /etc/containerd/certs.d/registry.cn-hangzhou.aliyuncs.com
cat > /etc/containerd/certs.d/registry.cn-hangzhou.aliyuncs.com/hosts.toml <<'EOF'
server = "https://registry.cn-hangzhou.aliyuncs.com"
EOF
```

### 一键全部

```bash
for reg in docker.io registry.k8s.io quay.io ghcr.io registry-1.docker.io; do
  mkdir -p /etc/containerd/certs.d/$reg
  cat > /etc/containerd/certs.d/$reg/hosts.toml <<EOF
server = "https://$reg"
[host."https://MIRROR.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
done
# docker.io 和 registry-1 的 mirror 名是 dockerhub
sed -i 's|MIRROR.ihome|dockerhub.ihome|' /etc/containerd/certs.d/docker.io/hosts.toml
sed -i 's|MIRROR.ihome|dockerhub.ihome|' /etc/containerd/certs.d/registry-1.docker.io/hosts.toml
sed -i 's|MIRROR.ihome|k8s.ihome|' /etc/containerd/certs.d/registry.k8s.io/hosts.toml
sed -i 's|MIRROR.ihome|quay.ihome|' /etc/containerd/certs.d/quay.io/hosts.toml
sed -i 's|MIRROR.ihome|ghcr.ihome|' /etc/containerd/certs.d/ghcr.io/hosts.toml

systemctl restart containerd
```

## 验证

```bash
ctr -n k8s.io image pull docker.io/library/nginx:alpine
ctr -n k8s.io image pull registry.k8s.io/pause:3.9
ctr -n k8s.io image pull quay.io/metallb/controller:v0.14.8
ctr -n k8s.io image pull ghcr.io/cloudnativelabs/gobgp:latest
```

## 加速源映射

| 上游 | 代理地址 |
|---|---|
| `docker.io` | `dockerhub.ihome.sxxpqp.top:8443` |
| `registry.k8s.io` | `k8s.ihome.sxxpqp.top:8443` |
| `quay.io` | `quay.ihome.sxxpqp.top:8443` |
| `ghcr.io` | `ghcr.ihome.sxxpqp.top:8443` |
| 阿里云 ACR | `registry.cn-hangzhou.aliyuncs.com/sxxpqp/` (直连推送) |

| 自建服务 | 地址 |
|---|---|
| Nexus 私服 | `nexus.ihome.sxxpqp.top:8443` |
| chfs 中转 | `chfs.sxxpqp.top:8443` |
| MinIO S3 | `ihome.sxxpqp.top:8443` |

## 文件

| 文件 | 说明 |
|---|---|
| [install.sh](install.sh) | 离线安装(二进制+systemd+内核参数) |
| [mirrors.sh](mirrors.sh) | 一键配全部加速源 |
| [containerd-install.sh](containerd-install.sh) | 旧版安装(保留) |
| [containerd-offline-install.md](containerd-offline-install.md) | 离线安装文档 |
| [add-nofile-limit.sh](add-nofile-limit.sh) | 调大文件句柄限制 |
