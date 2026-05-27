cat > /tmp/prometheus-values.yaml << 'EOF'
alertmanager:
  enabled: false

pushgateway:
  enabled: false

server:
  extraArgs:
    web.enable-remote-write-receiver: ""
    enable-feature: otlp-write-receiver    # 开启 OTLP endpoint

  # Prometheus 配置文件加 otlp 资源属性提升
  extraConfigmapMounts: []

  global:
    scrape_interval: 15s

  serverFiles:
    prometheus.yml:
      global:
        scrape_interval: 15s
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

helm upgrade prometheus prometheus-community/prometheus \
  -n monitoring \
  -f /tmp/prometheus-values.yaml

kubectl rollout status deployment prometheus-server -n monitoring