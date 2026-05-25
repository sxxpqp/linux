第一步：安装 OTel Operator
bash# 加 helm repo
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# 创建命名空间
kubectl create namespace observability

# 安装 Operator
helm install opentelemetry-operator open-telemetry/opentelemetry-operator \
  --namespace observability \
  --set manager.collectorImage.repository=otel/opentelemetry-collector-contrib \
  --set admissionWebhooks.certManager.enabled=true

# 等 Operator 就绪
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=opentelemetry-operator \
  -n observability \
  --timeout=120s

# 验证
kubectl get pods -n observability
# 应该看到 opentelemetry-operator-xxx Running

第二步：部署测试后端（Jaeger，看 Trace 用）
测试环境用 Jaeger all-in-one 最简单，不用配 Tempo + Grafana 那一套：
bashkubectl apply -f - <<'EOF'
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

第三步：部署 DaemonSet Collector
bashkubectl apply -f - <<'EOF'
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
        verbosity: basic          # 测试时开着，能在日志里看到 span

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
          hostPort: 4317            # 暴露到节点端口，Pod 才能访问
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

第四步：创建 Instrumentation CR
bashkubectl apply -f - <<'EOF'
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: auto-instrumentation
  namespace: test                 # 和你的应用在同一个 namespace
spec:
  exporter:
    endpoint: http://$(NODE_IP):4317   # 打到本节点 DaemonSet

  propagators:
    - tracecontext                # W3C 标准，跨服务传播 TraceID
    - baggage

  sampler:
    type: parentbased_always_on   # 采样决策交给 Collector

  java:
    image: ghcr.io/open-telemetry/opentelemetry-operator/autoinstrumentation-java:1.32.0
    env:
    - name: OTEL_INSTRUMENTATION_JDBC_ENABLED
      value: "true"
    - name: OTEL_INSTRUMENTATION_SPRING_WEB_ENABLED
      value: "true"
EOF

第五步：部署你的应用
bashkubectl apply -f - <<'EOF'
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
        # 关键注解，触发自动注入
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
        # 内存配置，和 limit 联动
        - name: JDK_JAVA_OPTIONS
          value: "-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0 -XX:+UseG1GC"

        # OTel 服务信息
        - name: OTEL_SERVICE_NAME
          value: "order-service"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "deployment.environment=test,service.version=1.0.0"

        # NODE_IP，让应用知道往哪里打数据
        - name: NODE_IP
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP

        # JAVA_TOOL_OPTIONS 不写，留给 Operator 注入 -javaagent
EOF

第六步：验证注入是否成功
bash# 1. 看 Pod 是否有 initContainer
kubectl describe pod -l app=order-service -n test | grep -A 10 "Init Containers"
# 应该看到 opentelemetry-auto-instrumentation-java

# 2. 看注入的环境变量
kubectl get pod -l app=order-service -n test -o yaml | grep -A 2 "JAVA_TOOL_OPTIONS"
# 应该看到 -javaagent:/otel-auto-instrumentation/javaagent.jar

# 3. 同时确认 JDK_JAVA_OPTIONS 还在
kubectl get pod -l app=order-service -n test -o yaml | grep -A 2 "JDK_JAVA_OPTIONS"
# 应该看到你配的内存参数，没有被覆盖

# 4. 看应用日志，JVM 启动时会打印 agent 加载信息
kubectl logs -l app=order-service -n test | grep -i "opentelemetry\|javaagent"
# 应该看到类似：
# [otel.javaagent 2024-xx-xx] INFO ... OpenTelemetry agent loaded

第七步：打几个请求，看 Trace
bash# 转发 Jaeger UI 到本地
kubectl port-forward svc/jaeger -n observability 16686:16686

# 另开终端打请求
curl http://localhost:8080/api/orders

# 浏览器打开
open http://localhost:16686
# Service 下拉选 order-service，点 Find Traces

常见报错速查
bash# Pod 一直 Pending，看 initContainer 状态
kubectl describe pod -l app=order-service -n test
# 如果 initContainer 拉镜像失败，换成能访问的镜像仓库地址

# Operator 没有触发注入，看 Operator 日志
kubectl logs -n observability \
  deployment/opentelemetry-operator-controller-manager \
  -c manager | grep -i "inject\|error"

# Collector 收不到数据，看 DaemonSet 日志
kubectl logs -n observability -l app=otel-collector-agent | tail -50

# 确认 hostPort 4317 在节点上监听
kubectl get pods -n observability -o wide   # 看 DaemonSet 跑在哪个节点
# ssh 上去
ss -tlnp | grep 4317