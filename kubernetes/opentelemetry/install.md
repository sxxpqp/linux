# OpenTelemetry Operator 安装指南

## 架构概览

```
┌─────────────┐     OTLP (4317)     ┌──────────────────┐     OTLP      ┌──────────┐
│  应用 Pod    │ ──────────────────→ │  DaemonSet Agent  │ ───────────→ │  Jaeger  │
│ (auto-instr) │    本节点 hostPort   │  (k8sattributes)  │              │  (UI)    │
└─────────────┘                      └──────────────────┘              └──────────┘
```

| 组件 | 说明 |
|------|------|
| **OTel Operator** | 管理 Instrumentation CR，自动注入 javaagent |
| **DaemonSet Collector** | 每节点一个，通过 hostPort 接收 Pod 数据，附上 k8s 元数据后转发 |
| **Jaeger all-in-one** | 测试环境用，同时接收 OTLP 并提供 UI 查看 Trace |

---

## 1. 安装 OTel Operator

```bash
# 添加 Helm 仓库
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# 创建命名空间
kubectl create namespace observability

# 安装 Operator
helm install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --namespace observability \
  --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib \
  --set admissionWebhooks.certManager.enabled=true

# 等待 Operator 就绪
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=opentelemetry-operator \
  -n observability \
  --timeout=120s

# 验证
kubectl get pods -n observability
# 预期输出：opentelemetry-operator-xxx Running
```

---

## 2. 部署 Jaeger（测试后端）

> 测试环境用 Jaeger all-in-one 最简单，无需 Tempo + Grafana 全套。

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
      - name: jaeger
        image: jaegertracing/all-in-one:1.55
        env:
        - name: COLLECTOR_OTLP_ENABLED
          value: "true"
        ports:
        - containerPort: 16686   # UI
        - containerPort: 4317    # OTLP gRPC
        - containerPort: 4318    # OTLP HTTP
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: observability
spec:
  selector:
    app: jaeger
  ports:
  - name: ui
    port: 16686
    targetPort: 16686
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
  - name: otlp-http
    port: 4318
    targetPort: 4318
EOF

kubectl wait --for=condition=ready pod \
  -l app=jaeger -n observability --timeout=60s
```

---

## 3. 部署 DaemonSet Collector

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-agent-config
  namespace: observability
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      memory_limiter:
        limit_mib: 400
        spike_limit_mib: 100
        check_interval: 5s
      k8sattributes:
        auth_type: serviceAccount
        extract:
          metadata:
            - k8s.pod.name
            - k8s.namespace.name
            - k8s.node.name
            - k8s.deployment.name
      batch:
        send_batch_size: 512
        timeout: 5s

    exporters:
      otlp/jaeger:
        endpoint: "jaeger.observability.svc.cluster.local:4317"
        tls:
          insecure: true
      debug:
        verbosity: basic

    service:
      pipelines:
        traces:
          receivers:  [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters:  [otlp/jaeger, debug]
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: observability
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector
rules:
- apiGroups: [""]
  resources: ["pods", "namespaces", "nodes"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-collector
subjects:
- kind: ServiceAccount
  name: otel-collector
  namespace: observability
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-collector-agent
  namespace: observability
spec:
  selector:
    matchLabels:
      app: otel-collector-agent
  template:
    metadata:
      labels:
        app: otel-collector-agent
    spec:
      serviceAccountName: otel-collector
      containers:
      - name: collector
        image: otel/opentelemetry-collector-contrib:0.96.0
        args: ["--config=/conf/config.yaml"]
        resources:
          requests:
            cpu: 100m
            memory: 200Mi
          limits:
            cpu: 500m
            memory: 500Mi
        ports:
        - containerPort: 4317
          hostPort: 4317
        - containerPort: 4318
          hostPort: 4318
        volumeMounts:
        - name: config
          mountPath: /conf
      volumes:
      - name: config
        configMap:
          name: otel-agent-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector-agent
  namespace: observability
spec:
  selector:
    app: otel-collector-agent
  ports:
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
  - name: otlp-http
    port: 4318
    targetPort: 4318
EOF

kubectl wait --for=condition=ready pod \
  -l app=otel-collector-agent -n observability --timeout=60s
```

### 数据流向

```
应用 Pod → hostPort:4317 → DaemonSet Collector → jaeger.observability:4317
                              │
                              ├─ k8sattributes（附上 pod/ns/node 元数据）
                              ├─ batch（攒满 512 条或 5s 再发）
                              └─ debug（控制台打印 span，测试用）
```

---

## 4. 创建 Instrumentation CR

> Instrumentation 必须和应用在**同一个 namespace**。

```bash
kubectl apply -f - <<'EOF'
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: auto-instrumentation
  namespace: test
spec:
  exporter:
    endpoint: http://$(NODE_IP):4317
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_always_on
  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:1.32.0
    env:
    - name: OTEL_INSTRUMENTATION_JDBC_ENABLED
      value: "true"
    - name: OTEL_INSTRUMENTATION_SPRING_WEB_ENABLED
      value: "true"
EOF
```

### 关键参数说明

| 参数 | 说明 |
|------|------|
| `spec.exporter.endpoint` | `$(NODE_IP)` 由应用 env 注入，指向本节点 DaemonSet |
| `propagators[0]: tracecontext` | W3C 标准，跨服务传播 TraceID |
| `sampler: parentbased_always_on` | 采样决策交给上游/Collector |
| `java.image` | 自动注入用的 javaagent 镜像 |

---

## 5. 部署应用

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: order-service
  template:
    metadata:
      labels:
        app: order-service
      annotations:
        instrumentation.opentelemetry.io/inject-java: "true"
    spec:
      containers:
      - name: app
        image: your-registry/order-service:latest
        resources:
          requests:
            memory: 512Mi
            cpu: 250m
          limits:
            memory: 1Gi
            cpu: 1000m
        env:
        - name: JDK_JAVA_OPTIONS
          value: "-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0 -XX:+UseG1GC"
        - name: OTEL_SERVICE_NAME
          value: "order-service"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "deployment.environment=test,service.version=1.0.0"
        - name: NODE_IP
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
EOF
```

### 注入原理

```
Operator 监听到 Pod 带有注解 ──→ 注入 initContainer（复制 javaagent.jar）
                                    │
                                    ▼
                              注入 JAVA_TOOL_OPTIONS = -javaagent:xxx.jar
                              （不覆盖 JDK_JAVA_OPTIONS，两个变量独立）
```

---

## 6. 验证注入

```bash
# 1. 检查 initContainer 是否注入
kubectl describe pod -l app=order-service -n test | grep -A 10 "Init Containers"
# 预期：opentelemetry-auto-instrumentation-java

# 2. 检查 JAVA_TOOL_OPTIONS
kubectl get pod -l app=order-service -n test -o yaml | grep -A 2 "JAVA_TOOL_OPTIONS"
# 预期：-javaagent:/otel-auto-instrumentation/javaagent.jar

# 3. 确认 JDK_JAVA_OPTIONS 未被覆盖
kubectl get pod -l app=order-service -n test -o yaml | grep -A 2 "JDK_JAVA_OPTIONS"
# 预期：你配的内存参数仍在

# 4. 检查 agent 加载日志
kubectl logs -l app=order-service -n test | grep -i "opentelemetry\|javaagent"
# 预期：[otel.javaagent ... ] INFO ... OpenTelemetry agent loaded
```

---

## 7. 发送请求查看 Trace

```bash
# 转发 Jaeger UI 到本地
kubectl port-forward svc/jaeger -n observability 16686:16686

# 发送测试请求
curl http://localhost:8080/api/orders

# 浏览器打开 Jaeger UI
# http://localhost:16686
# Service 下拉选 order-service → Find Traces
```

---

## 常见问题排查

### Pod Pending / InitContainer 失败

```bash
kubectl describe pod -l app=order-service -n test
# 检查 initContainer 镜像拉取状态，如果失败换成可访问的镜像仓库
```

### Operator 未触发注入

```bash
kubectl logs -n observability \
  deployment/opentelemetry-operator-controller-manager \
  -c manager | grep -i "inject\|error"
```

### Collector 收不到数据

```bash
# 查看 DaemonSet 日志
kubectl logs -n observability -l app=otel-collector-agent | tail -50

# 确认 hostPort 4317 在节点上监听
kubectl get pods -n observability -o wide
ss -tlnp | grep 4317
```