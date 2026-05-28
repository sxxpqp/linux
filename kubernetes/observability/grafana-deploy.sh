#!/bin/bash
# 更新 Grafana Helm release，读取本目录下的 grafana-values.yaml。
# 配置改动（数据源、Tempo→Logs 映射、derivedFields 等）后跑这个生效。
# 用法：bash grafana-deploy.sh
set -euo pipefail

NAMESPACE="observability"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "更新 Grafana (helm upgrade)..."
helm upgrade --install grafana grafana/grafana \
  -n "${NAMESPACE}" \
  -f "${DIR}/grafana-values.yaml" \
  --wait --timeout 3m

# datasource provisioning 不会热加载，必须重启 pod
echo ""
echo "重启 Grafana 让 datasource provisioning 生效..."
kubectl -n "${NAMESPACE}" rollout restart deploy/grafana
kubectl -n "${NAMESPACE}" rollout status deploy/grafana --timeout=120s

NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[0].address}')
echo ""
echo "Grafana: http://${NODE_IP}:30300"
echo "用户名: admin"
echo "密码:   admin123"
