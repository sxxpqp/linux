#!/bin/bash
# 卸载 MinIO Cluster.
#
# 注意:
#   terminationPolicy=Delete 会同时清掉 PVC (数据全没), 想保留数据先在 cluster.yaml 改成 Halt.
#   Console LB Service 卸载前要确保 metallb 还在跑, 否则 finalizer 会卡 (跟之前 kafka 那个坑一样).
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="${NS:-test}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns) NS="$2"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

echo "删除 Console LoadBalancer + 稳定 ClusterIP..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/console-service.yaml" \
  | kubectl delete -f - --ignore-not-found=true
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/stable-service.yaml" \
  | kubectl delete -f - --ignore-not-found=true
echo ""

echo "删除 MinIO Cluster..."
kubectl delete cluster.apps.kubeblocks.io minio-cluster -n "${NS}" --ignore-not-found=true
echo ""

echo "删除 ConfigMap/minio-cluster-endpoints..."
kubectl delete configmap minio-cluster-endpoints -n "${NS}" --ignore-not-found=true
echo ""

echo "确认残留 (PVC 应该已经被 Delete 策略带走, 没带走的话手动清理):"
kubectl get all,pvc,cm,secret -n "${NS}" -l app.kubernetes.io/instance=minio-cluster
