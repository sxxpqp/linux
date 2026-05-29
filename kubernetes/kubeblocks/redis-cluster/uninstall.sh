#!/bin/bash
# 卸载 KubeBlocks Redis Cluster 实例。
# 用法:
#   bash uninstall.sh                 # 删 Cluster CR (按 terminationPolicy 决定 PVC 命运)
#   bash uninstall.sh --ns prod
#   bash uninstall.sh --keep-data     # 临时改成 Halt, 保留 PVC
#   bash uninstall.sh --purge         # 临时改成 WipeOut, 一并删远程备份
#   bash uninstall.sh --dry-run       # 预演
set -uo pipefail

NS="test"
CLUSTER="redis-cluster"
POLICY=""        # 空 = 用 Cluster 原有的 terminationPolicy
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)         NS="$2"; shift 2 ;;
    --cluster)    CLUSTER="$2"; shift 2 ;;
    --keep-data)  POLICY="Halt"; shift ;;
    --purge)      POLICY="WipeOut"; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# //'
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

if ! kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" &>/dev/null; then
  echo "Cluster ${CLUSTER} 在 namespace=${NS} 下不存在, 无需卸载"
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
echo "  dry-run:             ${DRY_RUN}"
echo "========================================="
echo ""

# 提醒: DoNotTerminate 必须先 patch 才能删
if [ "${CUR_POLICY}" = "DoNotTerminate" ] && [ -z "${POLICY}" ]; then
  echo "⚠️  当前 terminationPolicy=DoNotTerminate, 必须先指定 --keep-data / --purge / Halt / Delete / WipeOut"
  echo "   常用: bash uninstall.sh --keep-data    (Halt, 保留数据)"
  echo "         bash uninstall.sh                (默认 Delete, 删 PVC, 但前面要先 patch)"
  exit 1
fi

# 危险操作前确认
case "${POLICY:-$CUR_POLICY}" in
  Delete|WipeOut)
    echo "⚠️  即将删除 PVC, 数据**永久丢失**"
    confirm "确认继续?"
    ;;
esac

# 如果指定了新策略, 先 patch 再删
if [ -n "${POLICY}" ] && [ "${POLICY}" != "${CUR_POLICY}" ]; then
  echo "Step 1: patch terminationPolicy → ${POLICY}"
  run kubectl patch cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
    --type=merge -p "{\"spec\":{\"terminationPolicy\":\"${POLICY}\"}}"
  echo ""
fi

# 删除 Cluster CR (operator 会按 terminationPolicy 处理后续)
echo "Step 2: 删除 Cluster CR"
run kubectl delete cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" --timeout=120s
echo ""

# 等 Pod 真的没了
echo "Step 3: 等 component pod 清理..."
for i in $(seq 1 30); do
  CNT=$(kubectl get pod -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" --no-headers 2>/dev/null | wc -l)
  [ "$CNT" -eq 0 ] && break
  echo "  [$i/30] 剩余 pod: $CNT"
  sleep 5
done

echo ""
echo "========================================="
echo " 卸载完成"
echo "========================================="
echo ""

# 显示剩余资源
echo "剩余 PVC:"
kubectl get pvc -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" 2>/dev/null || echo "  (无)"
echo ""
echo "剩余 Secret:"
kubectl get secret -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" 2>/dev/null || echo "  (无)"
