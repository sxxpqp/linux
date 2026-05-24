# Minikube 安装指南

## 一、安装 Minikube

```bash
# Linux AMD64
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube && rm minikube-linux-amd64

# macOS
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-darwin-amd64
sudo install minikube-darwin-amd64 /usr/local/bin/minikube && rm minikube-darwin-amd64

# ARM64 (如 Mac M1/M2/M3)
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-darwin-arm64
sudo install minikube-darwin-arm64 /usr/local/bin/minikube && rm minikube-darwin-arm64
```

## 二、配置加速源（国内必须）

Minikube 需要从 `k8s.gcr.io`、`registry.k8s.io` 拉取镜像，国内必须配置加速。

### 2.1 基础启动（阿里云镜像）

```bash
minikube start \
  --image-mirror-country cn \
  --registry-mirror=https://hub.ihome.sxxpqp.top:8443 \
  --base-image=registry.cn-hangzhou.aliyuncs.com/google_containers/kicbase:v0.0.46
```

参数说明：
- `--image-mirror-country cn` — 使用阿里云 k8s 镜像仓库替代 gcr.io
- `--registry-mirror` — Docker Hub 镜像加速（替换为自己的加速器地址）
- `--base-image` — Minikube 基础镜像（必须在国内环境下指定，否则拉取 kicbase 失败）

### 2.2 指定 K8s 版本 + 更多资源

```bash
minikube start \
  --image-mirror-country cn \
  --registry-mirror=https://hub.ihome.sxxpqp.top:8443 \
  --base-image=registry.cn-hangzhou.aliyuncs.com/google_containers/kicbase:v0.0.46 \
  --kubernetes-version=v1.28.3 \
  --cpus=4 \
  --memory=8g \
  --disk-size=40g
```

### 2.3 使用 Docker 驱动

```bash
# 确保已安装 Docker
minikube start \
  --driver=docker \
  --image-mirror-country cn \
  --registry-mirror=https://hub.ihome.sxxpqp.top:8443 \
  --base-image=registry.cn-hangzhou.aliyuncs.com/google_containers/kicbase:v0.0.46
```

### 2.4 配置持久化镜像加速

写入默认配置，后续 `minikube start` 无需重复传参：

```bash
minikube config set image-mirror-country cn
minikube config set registry-mirror https://hub.ihome.sxxpqp.top:8443
```

## 三、验证

```bash
# 查看集群状态
minikube status

# 查看节点
kubectl get node

# 查看系统 Pod
kubectl get pod -A

# 打开 Dashboard
minikube dashboard
```

## 四、常用命令

```bash
# 停止集群
minikube stop

# 删除集群
minikube delete

# 查看 IP
minikube ip

# 查看插件列表
minikube addons list

# 启用插件（如 ingress）
minikube addons enable ingress

# SSH 进入节点
minikube ssh

# 查看日志
minikube logs
```

## 五、常见问题

### Docker Hub 限速
配置 `--registry-mirror` 使用阿里云/网易/DaoCloud 加速器。

### kicbase 镜像拉取失败
确保指定 `--base-image` 为阿里云镜像仓库地址，或手动拉取：
```bash
docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/kicbase:v0.0.46
```

### 内存不足
Minikube 默认 2G 内存，低配机器可减少：
```bash
minikube start --memory=2g --cpus=2
```

### driver 冲突
若已安装 Docker，建议指定 `--driver=docker` 避免 virtualbox/hyperkit 问题。
