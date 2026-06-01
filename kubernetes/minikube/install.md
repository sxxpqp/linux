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

### 2.1 基础启动（完整配置）

```bash
# 确保已安装 Docker
minikube start \
  --force \
  --driver=docker \
  --cni=cilium \
  --image-mirror-country cn \
  --image-repository=registry.cn-hangzhou.aliyuncs.com/google_containers \
  --registry-mirror=https://hub.ihome.sxxpqp.top:8443 \
  --base-image=registry.cn-hangzhou.aliyuncs.com/google_containers/kicbase:v0.0.46 \
  --binary-mirror=https://nexus.ihome.sxxpqp.top:8443/repository/kubernetes-binaries \
  --kubernetes-version=v1.32.0 \
  --cpus=4 \
  --memory=8g \
  --disk-size=40g \
```

参数说明：
- `--force` — 使用 root 运行时必须加
- `--driver=docker` — 使用 Docker 驱动（推荐）
- `--cni=cilium` — 网络插件，支持 NetworkPolicy
- `--image-mirror-country cn` — 使用阿里云 k8s 镜像仓库替代 gcr.io
- `--registry-mirror` — Docker Hub 镜像加速
- `--base-image` — Minikube 基础镜像（国内必须指定）
- `--binary-mirror` — kubectl/kubeadm/kubelet 二进制下载镜像
- `--kubernetes-version` — 指定 K8s 版本（避免默认拉最新版导致镜像站 404）
- `--cpus` / `--memory` / `--disk-size` — 资源分配
- `--ports` — 端口映射（宿主机:minikube 容器），用于直接通过宿主机 IP 访问服务

### 2.2 多节点集群

```bash
minikube start \
  --force \
  --driver=docker \
  --cni=calico \
  --image-mirror-country cn \
  --registry-mirror=https://10291y.ihome.sxxpqp.top:8443 \
  --image-repository=registry.cn-hangzhou.aliyuncs.com/google_containers \
  --base-image=registry.cn-hangzhou.aliyuncs.com/google_containers/kicbase:v0.0.50 \
  --binary-mirror=https://nexus.ihome.sxxpqp.top:8443/repository/kubernetes-binaries \
  --nodes=3 \
  --cpus=4 \
  --memory=8g \
  --disk-size=40g \
  --kubernetes-version=v1.32.0
```

`--nodes=3` 表示 1 个 control-plane + 2 个 worker 节点。

### 2.3 指定版本 + 资源

```bash
minikube start \
  --force \
  --driver=docker \
  --image-mirror-country cn \
  --registry-mirror=https://10291y.ihome.sxxpqp.top:8443 \
  --image-repository=registry.cn-hangzhou.aliyuncs.com/google_containers \
  --base-image=registry.cn-hangzhou.aliyuncs.com/google_containers/kicbase:v0.0.50 \
  --binary-mirror=https://nexus.ihome.sxxpqp.top:8443/repository/kubernetes-binaries \
  --kubernetes-version=v1.28.3 \
  --cpus=2 \
  --memory=4g \
  --disk-size=20g \

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
# minikube addons enable ingress # 国内有点问题
      ## 下载官方 yaml
      curl -O https://nexus.ihome.sxxpqp.top:8443/kubernetes/ingress-nginx/main/deploy/static/provider/baremetal/deploy.yaml

      ## 批量替换镜像地址
      sed -i 's|registry.k8s.io|k8s.ihome.sxxpqp.top:8443|g' deploy.yaml

      ## 部署
      kubectl apply -f deploy.yaml
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
