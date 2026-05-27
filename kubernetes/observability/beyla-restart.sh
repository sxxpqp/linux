#!/bin/bash
set -e

echo "重启 Beyla DaemonSet..."

kubectl rollout restart daemonset beyla -n observability

kubectl rollout status daemonset beyla -n observability --timeout=120s

echo ""
echo "Beyla 已就绪，最近日志："
kubectl logs -n observability -l app=beyla --since=30s | tail -10
