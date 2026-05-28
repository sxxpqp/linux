#!/bin/bash
# 更新 Tempo Helm release，读取本目录下的 tempo-values.yaml。
# 用法：bash tempo-update.sh
set -euo pipefail

NAMESPACE="observability"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "更新 Tempo (helm upgrade)..."
helm upgrade --install tempo grafana/tempo-distributed \
  -n "${NAMESPACE}" \
  -f "${DIR}/tempo-values.yaml" \
  --wait --timeout 3m

echo ""
echo "Tempo 已就绪："
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=tempo
