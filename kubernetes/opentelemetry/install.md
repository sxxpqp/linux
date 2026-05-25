# OpenTelemetry Operator 安装指南（kind 测试环境）

## 架构概览

```
┌─────────────┐   OTLP (节点IP:4317)   ┌──────────────────┐    OTLP     ┌──────────┐
│  应用 Pod    │ ──────────────────────→ │  DaemonSet Agent  │ ──────────→ │  Jaeger  │
│ (auto-instr) │    hostPort 同节点      │  batch 处理       │             │  UI      │
└─────────────┘                          └──────────────────┘             └──────────┘
```

| 组件 | 说明 |
|------|------|
| **OTel Operator** | 管理 Instrumentation CR，自动注入 javaagent |
| **DaemonSet Collector** | 每节点一个，通过 hostPort 接收 Pod 数据后转发 |
| **Jaeger all-in-one** | 测试环境用，接收 OTLP 并提供 UI 查看 Trace |

> ⚠️ k8sattributes processor 需要访问 K8s API，kind 环境中不稳定，测试环境先去掉。

---

## 前置条件

```bash
kubectl get pods -n cert-manager

helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set installCRDs=true

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=cert-manager \
  -n cert-manager --timeout=120s
```

---

## 1. 安装 OTel Operator

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

kubectl create namespace observability

helm install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --namespace observability \
  --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib \
  --set admissionWebhooks.certManager.enabled=true

kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=opentelemetry-operator \
  -n observability --timeout=120s

kubectl get pods -n observability
```

---

## 2. 部署 Jaeger（测试后端）

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
        - containerPort: 16686
        - containerPort: 4317
        - containerPort: 4318
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: observability
spec:
  selector:
    app: jaeger
  type: NodePort
  ports:
  - name: ui
    port: 16686
    targetPort: 16686
    nodePort: 30686
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
  - name: otlp-http
    port: 4318
    targetPort: 4318
EOF

kubectl wait --for=condition=ready pod \
  -l app=jaeger -n observability --timeout=60s

# 记录 ClusterIP，下一步要用
kubectl get svc jaeger -n observability
```

---

## 3. 部署 DaemonSet Collector

```bash
# 获取 Jaeger ClusterIP
cat <<EOF | kubectl apply -f -
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
      batch:
        send_batch_size: 512
        timeout: 5s

    exporters:
      otlp/jaeger:
        endpoint: "jaeger:4317"
        tls:
          insecure: true
      debug:
        verbosity: basic

    service:
      pipelines:
        traces:
          receivers:  [otlp]
          processors: [memory_limiter, batch]
          exporters:  [otlp/jaeger, debug]
EOF

kubectl apply -f - <<'EOF'
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
EOF

kubectl wait --for=condition=ready pod \
  -l app=otel-collector-agent -n observability --timeout=60s
```

---

## 4. 创建 Instrumentation CR

> ⚠️ **关键**：endpoint 必须用 `$(OTEL_NODE_IP)`，不能用 `$(NODE_IP)`。
>
> - `OTEL_NODE_IP` 是 Operator **自动注入**的变量，值为节点 IP，K8s 会在容器启动时展开
> - `NODE_IP` 是自定义变量，Operator 注入时不认识，不会展开，变成字面字符串导致连接失败

```bash
kubectl create namespace test --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<'EOF'
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: auto-instrumentation
  namespace: test
spec:
  exporter:
    endpoint: http://$(OTEL_NODE_IP):4317
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

---

## 5. 部署应用

> ⚠️ **注意**：Spring Boot AOT（native image）不支持 Java agent 注入。
> `springcommunity/spring-petclinic` 是 AOT 版本，必须换用普通 JVM 镜像。

```bash
# 先在宿主机拉取，再 load 进 kind
docker pull docker.io/arey/springboot-petclinic:latest
kind load docker-image docker.io/arey/springboot-petclinic:latest --name kind

kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: petclinic
  namespace: test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: petclinic
  template:
    metadata:
      labels:
        app: petclinic
      annotations:
        instrumentation.opentelemetry.io/inject-java: "true"
    spec:
      containers:
      - name: app
        image: docker.io/arey/springboot-petclinic:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
        resources:
          requests:
            memory: 512Mi
            cpu: 250m
          limits:
            memory: 1Gi
            cpu: 1000m
        env:
        # 内存配置用 JDK_JAVA_OPTIONS（Java 9+），不占用 JAVA_TOOL_OPTIONS
        # JAVA_TOOL_OPTIONS 留给 Operator 注入 -javaagent，不要手写
        - name: JDK_JAVA_OPTIONS
          value: "-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0"
        - name: OTEL_SERVICE_NAME
          value: "petclinic"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "deployment.environment=test,service.version=1.0.0"
        # 不要自己定义 NODE_IP 和 OTEL_EXPORTER_OTLP_ENDPOINT
        # 由 Instrumentation CR 的 exporter.endpoint 统一控制
---
apiVersion: v1
kind: Service
metadata:
  name: petclinic
  namespace: test
spec:
  selector:
    app: petclinic
  ports:
  - port: 8080
    targetPort: 8080
EOF

kubectl rollout status deployment/petclinic -n test
```

---

## 6. 验证注入

```bash
# 1. 确认 initContainer 注入成功
kubectl describe pod -l app=petclinic -n test | grep -A5 "Init Containers"
# 预期：opentelemetry-auto-instrumentation-java

# 2. 确认 JAVA_TOOL_OPTIONS 有 javaagent
kubectl get pod -l app=petclinic -n test \
  -o jsonpath='{.items[0].spec.containers[0].env}' \
  | python3 -m json.tool | grep -A2 "JAVA_TOOL_OPTIONS"
# 预期：-javaagent:/otel-auto-instrumentation-java-app/javaagent.jar

# 3. 确认 JDK_JAVA_OPTIONS 内存参数未被覆盖
kubectl get pod -l app=petclinic -n test \
  -o jsonpath='{.items[0].spec.containers[0].env}' \
  | python3 -m json.tool | grep -A2 "JDK_JAVA_OPTIONS"
# 预期：-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0

# 4. 确认 OTLP endpoint 用了 OTEL_NODE_IP
kubectl get pod -l app=petclinic -n test \
  -o jsonpath='{.items[0].spec.containers[0].env}' \
  | python3 -m json.tool | grep -A2 "OTLP_ENDPOINT"
# 预期：http://$(OTEL_NODE_IP):4317

# 5. 确认 agent 加载成功
kubectl logs -l app=petclinic -n test | head -5
# 预期：
# Picked up JAVA_TOOL_OPTIONS: -javaagent:...
# [otel.javaagent ...] INFO ... opentelemetry-javaagent - version: 1.32.0
```

---

## 7. 发送请求查看 Trace

```bash
# 转发端口
kubectl port-forward svc/petclinic -n test 8080:8080 &

# 打请求（arey/springboot-petclinic 是 REST API）
for i in {1..10}; do
  curl -s http://localhost:8080/api/owners > /dev/null
  curl -s http://localhost:8080/api/vets > /dev/null
done

# 确认 Collector 收到数据
kubectl logs -n observability -l app=otel-collector-agent --since=30s \
  | grep -i "span\|ResourceSpan\|traces"

# 访问 Jaeger UI（NodePort，其他主机也可访问）
# http://<机器IP>:30686
# Service 选 petclinic，点 Find Traces
```

---

## 常见问题

### Collector 连不上 Jaeger（DNS 解析失败）

```bash
# 症状：dial tcp: lookup jaeger.observability.svc.cluster.local: connection refused
# 原因：kind DaemonSet Pod 跨节点 DNS 不稳定

JAEGER_IP=$(kubectl get svc jaeger -n observability -o jsonpath='{.spec.clusterIP}')
kubectl get configmap otel-agent-config -n observability -o yaml \
  | sed "s|jaeger.observability.svc.cluster.local|${JAEGER_IP}|g" \
  | kubectl apply -f -
kubectl rollout restart daemonset otel-collector-agent -n observability
```

### agent 未加载（日志没有 otel.javaagent）

```bash
# 检查是否是 AOT/native image
kubectl logs -l app=petclinic -n test | head -3
# 看到 "AOT-processed" 说明是 native image，必须换镜像
# 推荐：docker.io/arey/springboot-petclinic:latest（标准 JVM）
```

### OTLP endpoint 未展开（显示字面字符串）

```bash
# 症状：OTEL_EXPORTER_OTLP_ENDPOINT = http://$(NODE_IP):4317
# 原因：用了自定义变量名，Operator 不认识，改用 $(OTEL_NODE_IP)

kubectl patch instrumentation auto-instrumentation -n test \
  --type=merge \
  -p '{"spec":{"exporter":{"endpoint":"http://$(OTEL_NODE_IP):4317"}}}'
kubectl rollout restart deployment/petclinic -n test
```

### Pod 重启后数据又断了

```bash
# 症状：硬编码了 Collector Pod IP，Pod 重启后 IP 变了
# 原因：Pod IP 不固定，不能硬编码
# 解法：用 $(OTEL_NODE_IP) + hostPort
#       DaemonSet 在每个节点监听固定 hostPort 4317
#       无论 Pod 调度到哪个节点，永远打到同节点 Collector
```

### Operator 未触发注入

```bash
kubectl logs -n observability \
  deployment/opentelemetry-operator-controller-manager \
  -c manager | grep -i "inject\|error"

# 常见原因：
# 1. 注解拼写错误，正确写法：
#    instrumentation.opentelemetry.io/inject-java: "true"
# 2. Instrumentation CR 和应用不在同一 namespace
```