# Kubernetes Service 暴露机制 — 八种类型

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/learn/service-mechanism.md
> 状态: 学习笔记

K8s 把 Pod 暴露给客户端的所有方式。8 种各有适用场景,**不全是 Service**(`hostPort`/`hostNetwork` 是 Pod 字段),但实践里都属于"暴露 Pod"这件事的方案。

## TL;DR 选型表

| 方式 | 集群内可达 | 集群外可达 | 占节点端口 | 典型场景 |
|---|---|---|---|---|
| **ClusterIP** | ✓ | ✗ | ✗ | 集群内 RPC、服务间调用(默认) |
| **NodePort** | ✓ | ✓(`NodeIP:port`) | ✓ 30000-32767 | 临时对外暴露 / 没 Ingress 时 |
| **LoadBalancer** | ✓ | ✓(LB IP) | ✗ | 公有云、MetalLB 自动分 IP |
| **ExternalName** | ✓(CNAME) | — | ✗ | 集群内引用外部服务,只做 DNS 别名 |
| **Headless** (`clusterIP: None`) | ✓(直返 Pod IP 列表) | ✗ | ✗ | StatefulSet 配套、自己做服务发现 |
| **ExternalIPs** | ✓ | ✓(指定节点 IP) | 任意端口 | 用宿主机 IP + 任意端口对外 |
| **`hostPort`**(Pod 字段) | — | ✓ | ✓(指定端口) | DaemonSet 偶尔用,常被替代 |
| **`hostNetwork`**(Pod 字段) | — | ✓(直接用宿主机网络栈) | 整个 Pod 共享宿主网络 | 网络插件 / 日志采集 / 性能关键 |

---

## 1. ClusterIP — 默认类型,集群内 IP

通过 `selector` + label 自动选 Pod 并建 endpoint。

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:               # 通过 label 选择 Pod,自动建 endpoint
    app: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

### 变体:手动指定 Endpoints(不走 selector)

适用于"指向集群外的某台机器"或"自定义后端"。

```yaml
apiVersion: v1
kind: Endpoints
metadata:
  name: my-service-manual-endpoints
subsets:
  - addresses:
      - ip: 192.168.1.54   # 手动指定的 endpoint IP — Pod IP / 宿主 IP / 外部 IP 都行
    ports:
      - name: http         # 端口名要跟下面 Service 一致
        port: 80
        protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: my-service-manual-endpoints
spec:                       # 注意:没有 selector
  ports:
    - protocol: TCP
      port: 80
      name: http
```

## 2. NodePort — 占节点端口

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service-nodeport
spec:
  type: NodePort
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
      nodePort: 30080        # 不指定就在 30000-32767 随机分
```

## 3. LoadBalancer — 云 LB / MetalLB 分配外部 IP

公有云会自动建 LB,自建集群用 MetalLB / kube-vip。yaml 同 NodePort,改 `type: LoadBalancer`。

## 4. ExternalName — DNS 别名,只解析不代理

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service-externalname
spec:
  type: ExternalName
  externalName: www.baidu.com   # K8s DNS 会把这个 Service 解析成 CNAME → www.baidu.com
  ports:
    - port: 443
      targetPort: 443
```

集群内 Pod 访问 `nginx-service-externalname` → DNS 返回 CNAME `www.baidu.com`,流量**不走 kube-proxy**,直接出集群。

## 5. Headless — `clusterIP: None`,直返 Pod IP 列表

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service-headless
spec:
  clusterIP: None              # ★ 关键:声明 Headless
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  selector:
    app: nginx
```

DNS 查 `nginx-service-headless` 返回所有 Pod 的 IP 列表(A 记录),客户端自己挑。StatefulSet 配套用得最多。

## 6. ExternalIPs — 用宿主机 IP 对外

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service-exrernalips
spec:
  externalIPs:
    - 192.168.1.100             # 宿主机 IP;会建 kube-ipvs0 网卡
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  selector:
    app: nginx
```

## 7. `hostPort` — Pod 字段,绑宿主机端口

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 2                  # ⚠ 副本数不能 > 节点数(端口冲突)
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.7.9
          ports:
            - containerPort: 80
              name: ngpt
              hostPort: 31200    # 绑宿主机 31200 端口,iptables 转发到 Pod 80
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 200m, memory: 256Mi }
```

## 8. `hostNetwork` — Pod 共享宿主机网络

Pod 的 IP **就是宿主机 IP**,没有独立 netns。

### Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 2                    # ⚠ 副本数不能 > 节点数(端口冲突)
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      dnsPolicy: ClusterFirstWithHostNet   # ★ hostNetwork 必配 — 否则解析不到 cluster DNS
      hostNetwork: true                    # ★ Pod IP = 宿主 IP
      containers:
        - name: nginx
          image: nginx:1.7.9
          ports:
            - containerPort: 80
              name: ngpt
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 200m, memory: 256Mi }
```

### DaemonSet(每节点一个,常用)

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nginx-daemonset
spec:
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      dnsPolicy: ClusterFirstWithHostNet
      hostNetwork: true
      containers:
        - name: nginx
          image: nginx:1.7.9
          ports:
            - containerPort: 80
              name: ngpt
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 200m, memory: 256Mi }
```

### StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: nginx-statefulset
spec:
  serviceName: nginx-service-headless    # ★ 配套 Headless Service
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      dnsPolicy: ClusterFirstWithHostNet
      hostNetwork: true
      containers:
        - name: nginx
          image: nginx:1.7.9
          ports:
            - containerPort: 80
              name: ngpt
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits:   { cpu: 200m, memory: 256Mi }
```

---

## `dnsPolicy` 速查(配 `hostNetwork` 时必须改)

| 值 | 含义 |
|---|---|
| `ClusterFirst`(默认) | 先查 cluster DNS(coredns),失败 fallback 宿主 `/etc/resolv.conf` — **但 hostNetwork 模式下解析不到 cluster DNS** |
| `ClusterFirstWithHostNet` | 同上但 hostNetwork 模式下也能查 cluster DNS — **hostNetwork 必配这个** |
| `Default` | 用宿主 `/etc/resolv.conf` |
| `None` | 完全自定义,需配 `dnsConfig` |
