# Beyla eBPF 自动埋点（生产环境）

## 架构位置

```
App Pod → eBPF 内核拦截 → Beyla DaemonSet → OTLP → Alloy → Tempo
              (零侵入，应用无感知)
```

## 配置

### beyla-config.yaml

```yaml
# 通过 ConfigMap 挂载到 /etc/beyla/beyla-config.yml
discovery:
  instrument:
    - k8s_namespace: default      # 自动发现该 namespace 下所有 Service
      k8s_pod_labels:
        app: ".*"                 # 匹配所有 Pod
    # 多 namespace 加多个条目
    # - k8s_namespace: production

features:
  - http2
  - tls

otel_traces_export:
  # 发到 Alloy Service，用 DNS 而非 IP
  endpoint: http://alloy.observability:4318
  protocol: http/protobuf

otel_metrics_export:
  endpoint: http://alloy.observability:4318
  protocol: http/protobuf

attributes:
  kubernetes:
    enable: true

log_level: info            # 生产用 info，测试用 debug
```

### Deployment

**前置**：先部署 Alloy，确保 Service `alloy.observability` 已就绪。

方式 1 — kubectl 直接 apply（独立部署）：

```bash
# ServiceAccount + RBAC
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: beyla
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: beyla
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "services", "endpoints"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["replicasets", "deployments"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: beyla
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: beyla
subjects:
- kind: ServiceAccount
  name: beyla
  namespace: observability
EOF

# ConfigMap + DaemonSet
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: beyla-config
  namespace: observability
data:
  beyla-config.yml: |
    discovery:
      instrument:
        - k8s_namespace: default
    features:
      - http2
      - tls
    otel_traces_export:
      endpoint: http://alloy.observability:4318
      protocol: http/protobuf
    otel_metrics_export:
      endpoint: http://alloy.observability:4318
      protocol: http/protobuf
    attributes:
      kubernetes:
        enable: true
    log_level: info
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: beyla
  namespace: observability
spec:
  selector:
    matchLabels:
      app: beyla
  template:
    metadata:
      labels:
        app: beyla
    spec:
      hostPID: true
      hostNetwork: true
      serviceAccountName: beyla
      containers:
      - name: beyla
        image: grafana/beyla:latest
        securityContext:
          privileged: true
          runAsUser: 0
        env:
        - name: BEYLA_CONFIG_PATH
          value: /etc/beyla/beyla-config.yml
        volumeMounts:
        - name: beyla-config
          mountPath: /etc/beyla
        - name: sys-kernel
          mountPath: /sys/kernel
          readOnly: true
      volumes:
      - name: beyla-config
        configMap:
          name: beyla-config
      - name: sys-kernel
        hostPath:
          path: /sys/kernel
EOF
```

### 权限说明

| 参数 | 原因 |
|------|------|
| `hostPID: true` | 访问宿主机 PID 命名空间，关联进程名和服务 |
| `hostNetwork: true` | 抓取 Pod 网络流量 |
| `privileged: true` | 加载 eBPF 程序到内核 |
| `/sys/kernel` 挂载 | eBPF 需要读取内核调试信息 |

### 内核要求

- Linux kernel ≥ 5.14
- 验证：`uname -r`
- eBPF 支持验证：`ls /sys/kernel/btf/vmlinux`

### 应用代码里还埋点吗？

**保留原来的 OTel SDK 埋点不删。** Beyla 和代码埋点互补：

```
Beyla (eBPF) → HTTP/gRPC 调用耗时，服务间拓扑
  +
代码 OTel SDK → SQL 查询、Redis、Kafka、方法级调用链

两条线发出，共用 Alloy → Tempo 管道
```
