cat > /tmp/alloy-config.alloy << 'EOF'
// ============================
// 接收 OTLP（应用 / OTel SDK / Beyla）
// ============================
otelcol.receiver.otlp "default" {
  grpc {
    endpoint = "0.0.0.0:4317"
  }

  http {
    endpoint = "0.0.0.0:4318"
  }

  output {
    traces  = [otelcol.processor.batch.traces.input]
    metrics = [otelcol.processor.resource.metrics.input]
    logs    = [otelcol.processor.batch.logs.input]
  }
}

// ============================
// Metrics 资源标签增强
// ============================
otelcol.processor.resource "metrics" {
  attributes {
    action = "insert"
    key    = "cluster"
    value  = "prod-k8s"
  }

  output {
    metrics = [otelcol.processor.batch.metrics.input]
  }
}

// ============================
// Trace 批处理
// ============================
otelcol.processor.batch "traces" {
  send_batch_size = 512
  timeout         = "5s"

  output {
    traces = [otelcol.exporter.otlp.tempo.input]
  }
}

// ============================
// Metrics 批处理
// ============================
otelcol.processor.batch "metrics" {
  send_batch_size = 512
  timeout         = "5s"

  output {
    metrics = [otelcol.exporter.otlphttp.prometheus.input]
  }
}

// ============================
// Logs 批处理
// ============================
otelcol.processor.batch "logs" {
  send_batch_size = 512
  timeout         = "5s"

  output {
    logs = [otelcol.exporter.otlphttp.loki.input]
  }
}

// ============================
// 导出 Tempo
// ============================
otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo-distributor.observability.svc:4317"

    tls {
      insecure = true
    }
  }
}

// ============================
// 导出 Prometheus OTLP Receiver
// ============================
otelcol.exporter.otlphttp "prometheus" {
  client {
    endpoint = "http://prometheus-k8s.monitoring.svc:9090/api/v1/otlp/v1/metrics"
  }
}

// ============================
// 导出 Loki OTLP Endpoint
// ============================
otelcol.exporter.otlphttp "loki" {
  client {
    endpoint = "http://loki-gateway.monitoring.svc:80/otlp"
  }
}

// ============================
// Kubernetes Pod 日志采集
// ============================
local.file_match "pod_logs" {
  path_targets = [
    {
      __path__ = "/var/log/pods/*/*/*.log",
      job      = "kubernetes-pods",
    }
  ]

  sync_period = "5s"
}

// ============================
// Loki 文件日志 Source
// ============================
loki.source.file "pod_logs" {
  targets    = local.file_match.pod_logs.targets
  forward_to = [loki.process.logs.receiver]
}

// ============================
// 日志处理
// ============================
loki.process "logs" {

  // 解析 CRI 日志格式
  stage.cri {}

  // 从文件路径提取 K8s 元信息
  stage.regex {
    expression = "/var/log/pods/(?P<namespace>[^_]+)_(?P<pod>[^_]+)_[^/]+/(?P<container>[^/]+)/"
    source     = "filename"
  }

  // 设置 Loki Labels
  stage.labels {
    values = {
      namespace = "",
      pod       = "",
      container = "",
    }
  }

  // JSON 日志解析
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

  // 业务 Labels
  stage.labels {
    values = {
      level                       = "",
      service_name                = "",
      service_namespace           = "",
      deployment_environment_name = "",
    }
  }

  // Trace 关联元数据
  stage.structured_metadata {
    values = {
      trace_id = "",
      span_id  = "",
    }
  }

  forward_to = [loki.write.default.receiver]
}

// ============================
// 写入 Loki
// ============================
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

kubectl logs -n observability -l app=alloy --since=30s | tail -10