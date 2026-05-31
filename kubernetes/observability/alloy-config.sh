#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/observability/alloy-config.sh
# 更新 Alloy ConfigMap 并重启 DaemonSet 拉取新配置。
# 用法：bash alloy-config.sh
set -euo pipefail

NAMESPACE="observability"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "更新 alloy-config ConfigMap..."
kubectl create configmap alloy-config \
  -n "${NAMESPACE}" \
  --from-file=config.alloy="${DIR}/alloy-config.alloy" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "重启 Alloy DaemonSet..."
kubectl rollout restart daemonset alloy -n "${NAMESPACE}"
kubectl rollout status daemonset alloy -n "${NAMESPACE}" --timeout=120s

echo ""
echo "Alloy 已就绪，最近日志："
kubectl logs -n "${NAMESPACE}" -l app=alloy --since=30s | tail -10
