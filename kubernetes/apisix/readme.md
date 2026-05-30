# Apache APISIX 网关

K8s 上部署 APISIX + Dashboard + Ingress Controller。学习笔记

> Nexus 暂未代理 APISIX helm chart，下面直接使用官方源（需要能访问外网）。

## 方案一：All-in-one（推荐）

APISIX + Dashboard + Ingress Controller 一次性安装：

```bash
helm repo add apisix https://charts.apiseven.com
helm repo update

helm install apisix apisix/apisix \
  --namespace apisix \
  --create-namespace \
  --set etcd.replicaCount=1 \
  --set etcd.persistence.enabled=true \
  --set etcd.persistence.size=8Gi \
  --set dashboard.enabled=true \
  --set ingress-controller.enabled=true \
  --set ingress-controller.config.apisix.serviceNamespace=apisix
```

## 方案二：分开安装

### 1. 安装 APISIX（含 Dashboard）

```bash
helm repo add apisix https://charts.apiseven.com
helm repo update

helm install apisix apisix/apisix \
  --namespace apisix \
  --create-namespace \
  --set etcd.replicaCount=1 \
  --set etcd.persistence.enabled=true \
  --set etcd.persistence.size=8Gi \
  --set dashboard.enabled=true
```

### 2. 安装 Ingress Controller（单独）

```bash
helm repo add apisix https://apache.github.io/apisix-helm-chart
helm repo update

helm install apisix-ingress-controller apisix/apisix-ingress-controller \
  --namespace ingress-apisix \
  --create-namespace
```
