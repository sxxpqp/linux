#!/bin/bash
# 安装 Loki (Grafana Helm chart, SimpleScalable 模式)。
# 用法:
#   bash install.sh                # 默认用 values.yaml（MinIO 本地存储）
#   bash install.sh --s3           # 用 values-s3.yaml（外部 S3）
set -euo pipefail

NAMESPACE="monitoring"
DIR="$(cd "$(dirname "$0")" && pwd)"
VALUES_FILE="${DIR}/values.yaml"

for arg in "$@"; do
  case "$arg" in
    --s3) VALUES_FILE="${DIR}/values-s3.yaml" ;;
    -h|--help)
      sed -n '2,5p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $arg (使用 --help 查看用法)"; exit 1 ;;
  esac
done

if [ ! -f "${VALUES_FILE}" ]; then
  echo "ERROR: values 文件不存在: ${VALUES_FILE}"
  exit 1
fi

echo "========================================="
echo " Loki 安装"
echo "  namespace:  ${NAMESPACE}"
echo "  values:     ${VALUES_FILE##*/}"
echo "========================================="
echo ""

# Helm 仓库
echo "[1/3] 添加 Helm 仓库..."
helm repo add grafana https://nexus.ihome.sxxpqp.top:8443/repository/grafana/ --force-update 2>/dev/null \
  || helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update >/dev/null

# 命名空间
echo "[2/3] 准备命名空间 ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# 安装
echo "[3/3] 安装/升级 Loki..."
helm upgrade --install loki grafana/loki \
  -n "${NAMESPACE}" \
  -f "${VALUES_FILE}" \
  --set loki.auth_enabled=false \
  --wait --timeout 5m

echo ""
echo "========================================="
echo " Loki 已就绪"
echo "========================================="
kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=loki
echo ""
echo "网关地址（集群内）: http://loki-gateway.${NAMESPACE}.svc:80"
echo "推送日志           : http://loki-gateway.${NAMESPACE}.svc/loki/api/v1/push"
echo "OTLP 接收          : http://loki-gateway.${NAMESPACE}.svc/otlp"
