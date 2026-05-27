cat > /tmp/alloy-config.alloy << 'EOF'
// ============================
// 接收 OTLP（OTel SDK + Beyla）
// ============================
otelcol.receiver.otlp "default" {
  grpc { endpoint = "0.0.0.0:4317" }
  http { endpoint = "0.0.0.0:4318" }
  output {
    traces  = [otelcol.processor.batch.traces.input]
    metrics = [otelcol.processor.batch.metrics.input]
    logs    = [otelcol.processor.batch.logs.input]
  }
}

// ============================
// 批处理
// ============================
otelcol.processor.batch "traces" {
  send_batch_size = 512
  timeout         = "5s"
  output {
    traces = [otelcol.exporter.otlp.tempo.input]
  }
}

otelcol.processor.batch "metrics" {
  send_batch_size = 512
  timeout         = "5s"
  output {
    metrics = [otelcol.exporter.otlphttp.prometheus.input]
  }
}

otelcol.processor.batch "logs" {
  send_batch_size = 512
  timeout         = "5s"
  output {
    logs = [otelcol.exporter.otlphttp.loki.input]
  }
}

// ============================
// 导出 Tempo（traces）
// ============================
otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo-distributor.observability:4317"
    tls { insecure = true }
  }
}

// ============================
// 导出 Prometheus OTLP endpoint（metrics）
// 22784 要求直接走 OTLP，不是 remote write
// ============================
otelcol.exporter.otlphttp "prometheus" {
  client {
    endpoint = "http://prometheus-kube-prometheus-prometheus.monitoring.svc:9090/api/v1/otlp"
    tls { insecure = true }
  }
}

// ============================
// 导出 Loki OTLP endpoint（logs）
// 22784 要求用 Loki OTLP，不是文件采集
// ============================
otelcol.exporter.otlphttp "loki" {
  client {
    endpoint = "http://loki-gateway.monitoring.svc:80/otlp"
    tls { insecure = true }
  }
}

// ============================
// 文件采集日志（兜底，非 OTel SDK 的服务也能采）
// ============================
local.file_match "pod_logs" {
  path_targets = [{
    __path__ = "/var/log/pods/*/*/*.log",
    job      = "kubernetes-pods",
  }]
  sync_period = "5s"
}

loki.source.file "pod_logs" {
  targets    = local.file_match.pod_logs.targets
  forward_to = [loki.process.labels.receiver]
}

loki.process "labels" {
  stage.cri {}

  stage.regex {
    expression = "/var/log/pods/(?P<namespace>[^_]+)_(?P<pod>[^_]+)_[^/]+/(?P<container>[^/]+)/"
    source     = "filename"
  }

  stage.labels {
    values = {
      namespace = "",
      pod       = "",
      container = "",
    }
  }

  stage.json {
    expressions = {
      level                       = "level",
      service_name                = "service_name",
      service_namespace           = "k8s_namespace",
      deployment_environment_name = "environment",
      trace_id                    = "trace_id",
      span_id                     = "span_id",
    }
  }

  stage.labels {
    values = {
      level                       = ""
      service_name                = ""
      service_namespace           = ""
      deployment_environment_name = ""
    }
  }

  stage.structured_metadata {
    values = {
      trace_id = ""
      span_id  = ""
    }
  }

  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "http://loki-gateway.monitoring.svc:80/loki/api/v1/push"
  }
}
EOF

kubectl create configmap alloy-config \
  -n observability \
  --from-file=config.alloy=/tmp/alloy-config.alloy \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart daemonset alloy -n observability

kubectl wait --for=condition=ready pod \
  -l app=alloy -n observability --timeout=60s