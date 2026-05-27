#!/bin/bash
set -e

NAMESPACE="observability"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo " Observability 配置更新"
echo "========================================="
echo ""
# ---- 2. Tempo ----
echo "更新 Tempo..."
helm upgrade --install tempo grafana/tempo-distributed \
  -n ${NAMESPACE} \
  -f ${DIR}/tempo-values.yaml \
  --wait --timeout 3m
echo "  Tempo 就绪"
echo ""

