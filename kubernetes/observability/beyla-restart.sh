#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/observability/beyla-restart.sh
set -e

echo "重启 Beyla DaemonSet..."

kubectl rollout restart daemonset beyla -n observability

kubectl rollout status daemonset beyla -n observability --timeout=120s

echo ""
echo "Beyla 已就绪，最近日志："
kubectl logs -n observability -l app=beyla --since=30s | tail -10
