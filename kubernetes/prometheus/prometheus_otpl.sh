cat > /tmp/prometheus-values.yaml << 'EOF'
alertmanager:
  enabled: false

pushgateway:
  enabled: false

server:
  extraArgs:
    - web.enable-remote-write-receiver
    - enable-feature=otlp-receiver

  global:
    scrape_interval: 15s

  serverFiles:
    prometheus.yml:
      otlp:
        keep_identifying_resource_attributes: true
        promote_resource_attributes:
          - service.instance.id
          - service.name
          - service.namespace
          - deployment.environment.name
          - service.version
          - k8s.cluster.name
          - k8s.namespace.name
          - k8s.pod.name
          - k8s.deployment.name
          - k8s.node.name
EOF

# 1. 升级 Helm Release
helm upgrade prometheus prometheus-community/prometheus \
  -n monitoring \
  -f /tmp/prometheus-values.yaml

# 2. 强行删除旧 Pod，确保加载最新的 ConfigMap（有些版本的 Prometheus 在 rollout 时不会立刻重载 extraArgs）
kubectl delete pods -n monitoring -l app.kubernetes.io/component=server,app.kubernetes.io/name=prometheus

# 3. 等待新的 Deployment 滚动就绪
kubectl rollout status deployment prometheus-server -n monitoring
