#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/kafka/uninstall.sh
# 卸载 Kafka Cluster.
#
# 用法:
#   bash uninstall.sh                    # 默认删除 Cluster + PVC
#   bash uninstall.sh --keep-data        # 只删 Cluster, 保留 PVC
#   bash uninstall.sh --force            # 卡死时强制清理 (删 finalizer + Cluster + PVC)
#   bash uninstall.sh --ns prod
set -uo pipefail

NS="test"
CLUSTER="kafka-cluster"
KEEP_DATA=false
FORCE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)         NS="$2"; shift 2 ;;
    --keep-data)  KEEP_DATA=true; shift ;;
    --force)      FORCE=true; shift ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
  esac
done

echo "========================================="
echo " 卸载 Kafka Cluster"
echo "  namespace:   ${NS}"
echo "  cluster:     ${CLUSTER}"
echo "  keep-data:   ${KEEP_DATA}"
echo "  force:       ${FORCE}"
echo "========================================="
echo ""

EXISTS=$(kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" -o name 2>/dev/null || true)
if [ -z "$EXISTS" ]; then
  echo "Cluster 不存在, 跳过"
  exit 0
fi

if [ "$FORCE" = true ]; then
  echo "强制清理 finalizers..."
  kubectl patch cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
    --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true

  echo "强制删除 pod + pvc..."
  kubectl delete pod -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" --force --grace-period=0 2>/dev/null || true
  kubectl delete pvc -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" --force --grace-period=0 2>/dev/null || true
fi

if [ "$KEEP_DATA" = true ]; then
  echo "修改 terminationPolicy → Halt (保留 PVC)..."
  kubectl patch cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
    --type=merge -p '{"spec":{"terminationPolicy":"Halt"}}' 2>/dev/null || true
fi

echo "删除 Cluster..."
kubectl delete cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" --ignore-not-found=true --timeout=5m

if [ "$KEEP_DATA" = false ] && [ "$FORCE" = false ]; then
  echo "清理残留 PVC..."
  kubectl delete pvc -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" --ignore-not-found=true 2>/dev/null || true
fi

echo ""
echo "✓ 卸载完成"
echo ""
echo "验证:"
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=${CLUSTER}"
echo "  kubectl get pvc -n ${NS} -l app.kubernetes.io/instance=${CLUSTER}"
