#!/bin/bash
set -e

NAMESPACE="observability"

echo "========================================="
echo " Grafana 更新/部署"
echo "========================================="
echo ""

#helm repo add grafana https://grafana.github.io/helm-charts --force-update 2>/dev/null

helm upgrade --install grafana grafana/grafana \
  -n ${NAMESPACE} \
  -f grafana-values.yaml \
  --wait --timeout 3m

echo ""
echo "Grafana: http://$(kubectl get node -o jsonpath='{.items[0].status.addresses[0].address}'):30300"
echo "用户名: admin"
echo "密码: admin123"
