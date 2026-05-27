#!/bin/bash
set -e

NAMESPACE="observability"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================="
echo " Observability 配置更新"
echo "========================================="
echo ""

# ---- 1. Alloy ----
echo "[1/5] 更新 Alloy ConfigMap..."
kubectl create configmap alloy-config \
  -n ${NAMESPACE} \
  --from-file=config.alloy=${DIR}/alloy-config.alloy \
  --dry-run=client -o yaml | kubectl apply -f -

echo "      重启 Alloy DaemonSet..."
kubectl rollout restart daemonset alloy -n ${NAMESPACE}
kubectl rollout status daemonset alloy -n ${NAMESPACE} --timeout=60s
echo "  Alloy 就绪"
echo ""

# ---- 2. Tempo ----
echo "[2/5] 更新 Tempo..."
helm upgrade --install tempo grafana/tempo-distributed \
  -n ${NAMESPACE} \
  -f ${DIR}/tempo-values.yaml \
  --wait --timeout 3m
echo "  Tempo 就绪"
echo ""

# ---- 3. Beyla ----
echo "[3/5] 重启 Beyla..."
kubectl rollout restart daemonset beyla -n ${NAMESPACE}
kubectl rollout status daemonset beyla -n ${NAMESPACE} --timeout=120s
echo "  Beyla 就绪"
echo ""

# ---- 4. Grafana ----
echo "[4/5] 更新 Grafana..."
helm upgrade --install grafana grafana/grafana \
  -n ${NAMESPACE} \
  -f ${DIR}/grafana-values.yaml \
  --wait --timeout 3m
echo "  Grafana 就绪"
echo ""

# ---- 5. Test Apps ----
echo "[5/5] 更新测试应用..."
kubectl apply -f ${DIR}/test-apps.yaml
echo "  测试应用已更新"
echo ""

# ---- 验证 ----
echo "========================================="
echo " 各组件状态："
echo "========================================="
kubectl get pods -n ${NAMESPACE}

echo ""
echo "Grafana: http://$(kubectl get node -o jsonpath='{.items[0].status.addresses[0].address}'):30300"
