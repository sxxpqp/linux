#!/bin/bash
# 卸载 KubeBlocks MySQL 集群.
#
# 用法:
#   bash uninstall.sh                  # 按 terminationPolicy 决定 PVC 命运
#   bash uninstall.sh --ns prod
#   bash uninstall.sh --delete-pvc     # 同时删除 PVC (数据全没, 慎用)
#   bash uninstall.sh --keep-data      # 临时改成 Halt, 保留 PVC
#   bash uninstall.sh --force          # 卡死时强清 (剥 finalizer + force delete)
#   bash uninstall.sh --dry-run        # 预演
set -uo pipefail

NS="test"
CLUSTER="mysql-cluster"
POLICY=""
DELETE_PVC=false
DRY_RUN=false
FORCE=false
STUCK_TIMEOUT=60

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)          NS="$2"; shift 2 ;;
    --cluster)     CLUSTER="$2"; shift 2 ;;
    --delete-pvc)  DELETE_PVC=true; shift ;;
    --keep-data)   POLICY="Halt"; shift ;;
    --force)       FORCE=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

run() {
  echo "  \$ $*"
  [ "$DRY_RUN" = false ] && { "$@" || echo "  (失败, 继续)"; }
}

confirm() {
  [ "$DRY_RUN" = true ] && return 0
  read -r -p "$1 [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "中止"; exit 1; }
}

force_cleanup() {
  echo "  开始强清 (剥 finalizer + force delete)..."
  for kind in pod instanceset.workloads.kubeblocks.io component.apps.kubeblocks.io cluster.apps.kubeblocks.io; do
    for r in $(kubectl get -n "${NS}" "$kind" -o name 2>/dev/null | grep -i "${CLUSTER}"); do
      echo "    → $r"
      [ "$DRY_RUN" = false ] && {
        kubectl patch -n "${NS}" "$r" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete -n "${NS}" "$r" --grace-period=0 --force --ignore-not-found 2>/dev/null || true
      }
    done
  done
  if [ "$DELETE_PVC" = true ] || [ "$FORCE" = true ]; then
    for pvc in $(kubectl get pvc -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" -o name 2>/dev/null); do
      echo "    → $pvc"
      [ "$DRY_RUN" = false ] && {
        kubectl patch -n "${NS}" "$pvc" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete -n "${NS}" "$pvc" --grace-period=0 --force --ignore-not-found 2>/dev/null || true
      }
    done
  fi
}

if ! kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" &>/dev/null; then
  echo "Cluster ${CLUSTER} 在 namespace=${NS} 下不存在"
  [ "$FORCE" = true ] && { echo "继续 --force 兜底清理残留..."; force_cleanup; }
  exit 0
fi

CUR_POLICY=$(kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
  -o jsonpath='{.spec.terminationPolicy}' 2>/dev/null)

echo "========================================="
echo " MySQL 集群卸载"
echo "  namespace:              ${NS}"
echo "  cluster:                ${CLUSTER}"
echo "  当前 terminationPolicy: ${CUR_POLICY}"
echo "  delete-pvc:             ${DELETE_PVC}"
echo "  force:                  ${FORCE}"
echo "  dry-run:                ${DRY_RUN}"
echo "========================================="
echo ""

if [ "${CUR_POLICY}" = "DoNotTerminate" ] && [ -z "${POLICY}" ] && [ "$FORCE" = false ]; then
  echo "⚠️  terminationPolicy=DoNotTerminate, 需指定 --keep-data / --delete-pvc / --force 之一"
  exit 1
fi

if [ "$DELETE_PVC" = true ] || [ "$FORCE" = true ]; then
  echo "⚠️  PVC 将被删除, 数据**永久丢失**"
  confirm "确认继续?"
fi

if [ "$FORCE" = true ]; then
  force_cleanup
else
  if [ -n "${POLICY}" ] && [ "${POLICY}" != "${CUR_POLICY}" ]; then
    echo "patch terminationPolicy → ${POLICY}"
    run kubectl patch cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
      --type=merge -p "{\"spec\":{\"terminationPolicy\":\"${POLICY}\"}}"
    echo ""
  fi

  echo "删除 Cluster CR (${STUCK_TIMEOUT}s 无响应转 --force)..."
  [ "$DRY_RUN" = false ] && kubectl delete cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" --wait=false 2>/dev/null || true
  echo ""

  STUCK=true
  for i in $(seq 1 $((STUCK_TIMEOUT / 5))); do
    CL=$(kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" --no-headers 2>/dev/null | wc -l)
    POD=$(kubectl get pod -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" --no-headers 2>/dev/null | wc -l)
    echo "  [$i/$((STUCK_TIMEOUT / 5))] cluster=${CL}, pod=${POD}"
    [ "$CL" -eq 0 ] && [ "$POD" -eq 0 ] && { STUCK=false; break; }
    sleep 5
  done
  [ "$STUCK" = true ] && { echo "⚠️  超时, 切换强清..."; force_cleanup; }
fi

# 删 Secret
echo ""
echo "删除 Secret/mysql-cluster-password..."
[ "$DRY_RUN" = false ] && kubectl delete secret mysql-cluster-password -n "${NS}" --ignore-not-found

# 手动删 PVC (非 force 模式, 用户指定 --delete-pvc)
if [ "$DELETE_PVC" = true ] && [ "$FORCE" = false ]; then
  echo "删除 PVC..."
  [ "$DRY_RUN" = false ] && kubectl delete pvc -n "${NS}" \
    -l app.kubernetes.io/instance="${CLUSTER}" --ignore-not-found
fi

echo ""
echo "========================================="
echo " 卸载完成"
echo "========================================="
echo ""
echo "剩余 pod:"
kubectl get pod -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" 2>/dev/null || echo "  (无)"
echo ""
echo "剩余 PVC:"
kubectl get pvc -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" 2>/dev/null || echo "  (无)"
