#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/uninstall.sh
# 卸载 KubeBlocks operator。
# 用法:
#   bash uninstall.sh                # 保留 CRD 和现有 Cluster CR
#   bash uninstall.sh --purge        # 同时删 CRD + 所有 Cluster + PVC (业务数据丢失!)
#   bash uninstall.sh --dry-run      # 预演
set -uo pipefail

NAMESPACE="kb-system"
PURGE=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --purge)   PURGE=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      sed -n '2,6p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $arg (使用 --help 查看用法)"; exit 1 ;;
  esac
done

run() {
  echo "  \$ $*"
  [ "$DRY_RUN" = false ] && { "$@" || echo "  (失败，继续)"; }
}

confirm() {
  [ "$DRY_RUN" = true ] && return 0
  read -r -p "$1 [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "中止"; exit 1; }
}

echo "========================================="
echo " KubeBlocks 卸载"
echo "  namespace: ${NAMESPACE}"
echo "  purge:     ${PURGE}  (--purge 会删所有 Cluster 实例和 PVC)"
echo "  dry-run:   ${DRY_RUN}"
echo "========================================="
echo ""

if [ "$PURGE" = true ]; then
  echo "⚠️  --purge 模式会删除集群内所有 KubeBlocks 创建的实例 (Redis/MySQL/PG 等) 和它们的 PVC"
  confirm "确认继续?"
fi

# ---------- 1. 删除所有 Cluster 实例 (仅 --purge) ----------
if [ "$PURGE" = true ]; then
  echo "[1/3] 删除所有 KubeBlocks Cluster 实例..."
  if kubectl get cluster.apps.kubeblocks.io -A &>/dev/null; then
    run kubectl delete cluster.apps.kubeblocks.io --all -A --timeout=120s
  else
    echo "  (没有 Cluster CR)"
  fi
  echo ""
fi

# ---------- 2. helm uninstall ----------
echo "[2/3] 卸载 KubeBlocks helm release..."
if helm -n "${NAMESPACE}" status kubeblocks >/dev/null 2>&1; then
  run helm -n "${NAMESPACE}" uninstall kubeblocks
else
  echo "  (kubeblocks release 不存在，跳过)"
fi
echo ""

# ---------- 3. 清理 CRD + namespace (仅 --purge) ----------
if [ "$PURGE" = true ]; then
  echo "[3/3] 清理 CRD + namespace..."

  # KubeBlocks 自带 CRD 列表
  CRDS=$(kubectl get crd -o name 2>/dev/null | grep -E "kubeblocks.io|apecloud.com" || true)
  if [ -n "$CRDS" ]; then
    echo "$CRDS" | while read -r crd; do
      run kubectl delete --ignore-not-found "$crd"
    done
  fi

  run kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=60s
else
  echo "[3/3] 保留 CRD + namespace（重跑 bash uninstall.sh --purge 一并清理）"
fi
echo ""

echo "========================================="
echo " 卸载完成"
echo "========================================="
echo ""
echo "注意："
echo "  - 默认模式 PVC 不会删除，业务数据保留"
echo "  - 卸载 operator 后已存在的 Pod/Service 仍能正常跑（只是不再被 reconcile）"
