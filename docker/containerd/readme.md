# Containerd 安装与配置

## 文件

| 文件 | 说明 |
|---|---|
| [install.sh](install.sh) | 离线安装(二进制+systemd+内核参数) |
| [mirrors.sh](mirrors.sh) | **全部镜像加速源**(docker.io / k8s.io / quay.io / ghcr.io) |
| [containerd-install.sh](containerd-install.sh) | 旧版安装(保留参考) |
| [containerd-offline-install.md](containerd-offline-install.md) | 离线安装文档 |
| [add-nofile-limit.sh](add-nofile-limit.sh) | 调大文件句柄限制 |

## 加速源映射

| 上游 | 代理地址 |
|---|---|
| `docker.io` | `dockerhub.ihome.sxxpqp.top:8443` |
| `registry.k8s.io` | `k8s.ihome.sxxpqp.top:8443` |
| `quay.io` | `quay.ihome.sxxpqp.top:8443` |
| `ghcr.io` | `ghcr.ihome.sxxpqp.top:8443` |
| `registry.cn-hangzhou.aliyuncs.com` | 直连(阿里云 ACR) |

## 配置加速

```bash
# 一键配全部
bash mirrors.sh

# 验证
systemctl restart containerd
ctr -n k8s.io image pull docker.io/library/nginx:alpine
ctr -n k8s.io image pull registry.k8s.io/pause:3.9
ctr -n k8s.io image pull quay.io/metallb/controller:v0.14.8
```

## 手动加单个

```bash
mkdir -p /etc/containerd/certs.d/ghcr.io
cat > /etc/containerd/certs.d/ghcr.io/hosts.toml <<'EOF'
server = "https://ghcr.io"
[host."https://ghcr.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
systemctl restart containerd
```

## 前置: config.toml 开 certs.d

```bash
# 确认已开(install.sh 已自动设):
grep certs.d /etc/containerd/config.toml
# 期望: config_path = "/etc/containerd/certs.d"

# 没开的话:
sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|' /etc/containerd/config.toml
systemctl restart containerd
```
