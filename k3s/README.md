# K3s 轻量级 Kubernetes

K3s 轻量级 K8s 发行版，适合边缘计算、IoT、资源受限环境。

## 说明

| 内容 | 说明 |
|---|---|
| K3s 快速安装 | 单节点部署，适合频繁更换 IP 场景 |
| Docker 运行时安装 | 使用 containerd 或 docker 作为容器运行时 |
| 版本指定 | 默认安装最新版，支持指定版本（如 v1.21.14-k3s1） |

## 快速安装

```bash
# 安装最新版（国内镜像）
curl -sfL https://rancher-mirror.oss-cn-beijing.aliyuncs.com/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -

# 使用 docker 运行时
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -s - --docker
```
