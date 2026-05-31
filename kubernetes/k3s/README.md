# K3s 轻量级 Kubernetes

K3s 轻量级 K8s 发行版，适合边缘计算、IoT、资源受限环境。

## 快速安装

```bash
# 安装最新版（国内镜像）
curl -sfL https://rancher-mirror.oss-cn-beijing.aliyuncs.com/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -

# 使用 docker 运行时
curl -sfL https://rancher-mirror.rancher.cn/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -s - --docker
```

## 说明

| 内容 | 说明 |
|---|---|
| 安装方式 | 单节点部署，适合频繁更换 IP 场景（curl 一键安装，国内镜像加速） |
| 容器运行时 | 默认 containerd，支持 `--docker` 参数切换 Docker 运行时 |
| 版本指定 | 默认安装最新稳定版，支持指定版本（如 `INSTALL_K3S_VERSION=v1.21.14-k3s1`） |
