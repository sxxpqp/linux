#!/bin/bash
# VM 监控栈一键启动 & 关闭
# 用法: ./quick-start.sh [start|stop|status]

set -e

ACTION=${1:-start}

case "$ACTION" in
  start)
    echo "🚀 启动 VM 监控栈..."
    docker compose up -d
    echo ""
    echo "✅ 已启动："
    echo "   Prometheus:   http://localhost:9090"
    echo "   Grafana:      http://localhost:3000  (admin/admin)"
    echo "   Node Exporter: http://localhost:9100/metrics"
    echo "   Blackbox:     http://localhost:9115"
    echo ""
    echo "📌 导入 Grafana 面板 ID: 1860 (Node Exporter Full)"
    ;;
  stop)
    echo "🛑 停止 VM 监控栈..."
    docker compose down
    ;;
  status)
    docker compose ps
    ;;
  *)
    echo "用法: $0 [start|stop|status]"
    exit 1
    ;;
esac
