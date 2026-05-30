#!/bin/bash
# 卸载 MinIO 集群 (Bitnami helm chart 模式)
#
# 注意:
#   1. helm uninstall 不会删 PVC (StatefulSet 默认保留),想清数据见下方 --wipe.
#   2. 删 LB Service 前确保 metallb 还在跑, 否则 finalizer 会卡.
#
# 用法:
#   bash uninstall.sh                # 默认 ns=test, 保留 PVC 数据
#   bash uninstall.sh --ns prod
#   bash uninstall.sh --delete-pvc   # 同时删除 PVC (数据全没,慎用)
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="${NS:-test}"
RELEASE_NAME="minio-cluster"
DELETE_PVC=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)    NS="$2"; shift 2 ;;
    --delete-pvc) DELETE_PVC=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

echo "删除 Console LoadBalancer Service..."
sed -e "s|namespace: test|namespace: ${NS}|" \
    -e "s|__RELEASE_NAME__|${RELEASE_NAME}|g" \
    "${DIR}/console-service.yaml" \
  | kubectl delete -f - --ignore-not-found=true
echo ""

echo "helm uninstall ${RELEASE_NAME}..."
helm uninstall "${RELEASE_NAME}" -n "${NS}" || true
echo ""

echo "删除 ConfigMap/${RELEASE_NAME}-endpoints..."
kubectl delete configmap "${RELEASE_NAME}-endpoints" -n "${NS}" --ignore-not-found=true
echo ""

if [ "$DELETE_PVC" = true ]; then
  echo "[--delete-pvc] 删除 PVC (数据全没)..."
  kubectl delete pvc -n "${NS}" -l app.kubernetes.io/instance="${RELEASE_NAME}" --ignore-not-found=true
  kubectl delete secret -n "${NS}" -l app.kubernetes.io/instance="${RELEASE_NAME}" --ignore-not-found=true
  echo ""
fi

echo "确认残留:"
kubectl get all,pvc,cm,secret -n "${NS}" -l app.kubernetes.io/instance="${RELEASE_NAME}"
echo ""

if [ "$DELETE_PVC" = false ]; then
  echo "提示: PVC 已保留 (数据还在). 想彻底清理重跑 --delete-pvc."
  echo "  kubectl get pvc -n ${NS} -l app.kubernetes.io/instance=${RELEASE_NAME}"
fi
