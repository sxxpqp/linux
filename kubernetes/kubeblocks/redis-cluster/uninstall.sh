#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/redis-cluster/uninstall.sh
# 卸载 KubeBlocks Redis Cluster 实例。
# 用法:
#   bash uninstall.sh                 # 标准删除 (按 terminationPolicy 决定 PVC 命运)
#   bash uninstall.sh --ns prod
#   bash uninstall.sh --keep-data     # 临时改成 Halt, 保留 PVC
#   bash uninstall.sh --purge         # 临时改成 WipeOut, 一并删远程备份
#   bash uninstall.sh --force         # 卡死时强清 (剥 finalizer + force delete + 删 PVC)
#   bash uninstall.sh --dry-run       # 预演
set -uo pipefail

NS="test"
CLUSTER="redis-cluster"
POLICY=""        # 空 = 用 Cluster 原有的 terminationPolicy
DRY_RUN=false
FORCE=false
STUCK_TIMEOUT=60  # 等待标准删除的秒数, 超过就自动转 force

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)         NS="$2"; shift 2 ;;
    --cluster)    CLUSTER="$2"; shift 2 ;;
    --keep-data)  POLICY="Halt"; shift ;;
    --purge)      POLICY="WipeOut"; shift ;;
    --force)      FORCE=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
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

# ---------- 强清: 剥 finalizer + force delete 所有相关资源 ----------
# 按依赖逆序: pod -> instanceset -> component -> cluster
# 每一类都先 patch 清空 finalizer, 再 --force --grace-period=0 删
force_cleanup() {
  echo "  开始强清 (剥 finalizer + force delete)..."
  for kind in pod instanceset.workloads.kubeblocks.io component.apps.kubeblocks.io cluster.apps.kubeblocks.io; do
    # grep 按 cluster 名筛, 避免误伤其他实例
    for r in $(kubectl get -n "${NS}" "$kind" -o name 2>/dev/null | grep -i "${CLUSTER}"); do
      echo "    → $r"
      [ "$DRY_RUN" = false ] && {
        kubectl patch -n "${NS}" "$r" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete -n "${NS}" "$r" --grace-period=0 --force --ignore-not-found 2>/dev/null || true
      }
    done
  done

  # PVC 单独处理 (Delete/WipeOut/--force 模式才删)
  if [ "$FORCE" = true ] || [ "${POLICY:-$CUR_POLICY}" = "Delete" ] || [ "${POLICY:-$CUR_POLICY}" = "WipeOut" ]; then
    for pvc in $(kubectl get pvc -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" -o name 2>/dev/null); do
      echo "    → $pvc"
      [ "$DRY_RUN" = false ] && {
        kubectl patch -n "${NS}" "$pvc" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
        kubectl delete -n "${NS}" "$pvc" --grace-period=0 --force --ignore-not-found 2>/dev/null || true
      }
    done
  fi
}

# ---------- 检查 Cluster 是否存在 ----------
if ! kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" &>/dev/null; then
  echo "Cluster ${CLUSTER} 在 namespace=${NS} 下不存在"
  # 但可能有残留 instanceset/component/pod/pvc, 仍跑一次强清兜底
  if [ "$FORCE" = true ]; then
    echo "继续 --force 兜底清理残留资源..."
    force_cleanup
  fi
  exit 0
fi

CUR_POLICY=$(kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
  -o jsonpath='{.spec.terminationPolicy}' 2>/dev/null)

echo "========================================="
echo " Redis Cluster 卸载"
echo "  namespace:           ${NS}"
echo "  cluster:             ${CLUSTER}"
echo "  当前 terminationPolicy: ${CUR_POLICY}"
echo "  本次使用的策略:        ${POLICY:-$CUR_POLICY (沿用原值)}"
echo "  force mode:          ${FORCE}"
echo "  dry-run:             ${DRY_RUN}"
echo "========================================="
echo ""

# DoNotTerminate 必须先指定新策略才能删
if [ "${CUR_POLICY}" = "DoNotTerminate" ] && [ -z "${POLICY}" ] && [ "$FORCE" = false ]; then
  echo "⚠️  当前 terminationPolicy=DoNotTerminate, 必须指定 --keep-data / --purge / --force 之一"
  exit 1
fi

# 危险操作前确认
case "${POLICY:-$CUR_POLICY}" in
  Delete|WipeOut)
    echo "⚠️  即将删除 PVC, 数据**永久丢失**"
    confirm "确认继续?"
    ;;
esac
if [ "$FORCE" = true ]; then
  echo "⚠️  --force 模式会剥所有 finalizer 并强删 PVC, 数据**永久丢失**, 慎用!"
  confirm "确认继续?"
fi

# ---------- 模式分支 ----------
if [ "$FORCE" = true ]; then
  # 直接强清, 不走 operator 的优雅删除
  echo "Step 1: --force 模式, 跳过 operator, 直接强清"
  force_cleanup
else
  # 标准流程: 改 policy → 删 cluster → 等清理 → 卡住自动转 force
  if [ -n "${POLICY}" ] && [ "${POLICY}" != "${CUR_POLICY}" ]; then
    echo "Step 1: patch terminationPolicy → ${POLICY}"
    run kubectl patch cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
      --type=merge -p "{\"spec\":{\"terminationPolicy\":\"${POLICY}\"}}"
    echo ""
  fi

  echo "Step 2: 删除 Cluster CR + 稳定 Service (后台异步, ${STUCK_TIMEOUT}s 没结果转 --force)"
  if [ "$DRY_RUN" = false ]; then
    kubectl delete cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" --wait=false 2>/dev/null || true
    kubectl delete svc "${CLUSTER}" -n "${NS}" --ignore-not-found 2>/dev/null || true
  fi
  echo ""

  echo "Step 3: 等 cluster + 下游资源清理 (最多 ${STUCK_TIMEOUT}s)..."
  STUCK=true
  for i in $(seq 1 $((STUCK_TIMEOUT / 5))); do
    CL_EXIST=$(kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" --no-headers 2>/dev/null | wc -l)
    POD_CNT=$(kubectl get pod -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" --no-headers 2>/dev/null | wc -l)
    echo "  [$i/$((STUCK_TIMEOUT / 5))] cluster=${CL_EXIST}, pod=${POD_CNT}"
    if [ "$CL_EXIST" -eq 0 ] && [ "$POD_CNT" -eq 0 ]; then
      STUCK=false
      break
    fi
    sleep 5
  done

  if [ "$STUCK" = true ]; then
    echo ""
    echo "⚠️  ${STUCK_TIMEOUT}s 内没清干净, 切换到强清模式..."
    force_cleanup
  fi
fi

echo ""
echo "========================================="
echo " 卸载完成"
echo "========================================="
echo ""

# 显示剩余资源
echo "剩余 cluster/component/instanceset:"
kubectl get cluster,component,instanceset -n "${NS}" 2>/dev/null | grep -i "${CLUSTER}" || echo "  (无)"
echo ""
echo "剩余 pod:"
kubectl get pod -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" 2>/dev/null || echo "  (无)"
echo ""
echo "剩余 PVC:"
kubectl get pvc -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" 2>/dev/null || echo "  (无)"
echo ""
echo "剩余 Secret:"
kubectl get secret -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" 2>/dev/null || echo "  (无)"
