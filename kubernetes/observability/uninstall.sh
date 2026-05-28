#!/bin/bash
# 卸载 LGTM + Beyla 可观测性栈。
# 用法:
#   bash uninstall.sh             # 标准卸载，保留 PVC/PV/namespace 和历史数据
#   bash uninstall.sh --purge     # 完整卸载，连同 PVC/PV/namespace 一起删（数据丢失）
#   bash uninstall.sh --dry-run   # 只打印会做什么，不真的执行
set -uo pipefail

NAMESPACE="observability"
DIR="$(cd "$(dirname "$0")" && pwd)"
PURGE=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --purge)   PURGE=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $arg (使用 --help 查看用法)"
      exit 1 ;;
  esac
done

run() {
  echo "  \$ $*"
  if [ "$DRY_RUN" = false ]; then
    "$@" || echo "  (上一步失败，继续)"
  fi
}

confirm() {
  if [ "$DRY_RUN" = true ]; then return 0; fi
  read -r -p "$1 [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "中止"; exit 1; }
}

echo "========================================="
echo " LGTM + Beyla 卸载"
echo "  namespace: ${NAMESPACE}"
echo "  purge:     ${PURGE}    (--purge 会删除 PVC/PV/namespace)"
echo "  dry-run:   ${DRY_RUN}"
echo "========================================="
echo ""

if [ "$PURGE" = true ]; then
  echo "⚠️  --purge 模式会**永久丢失**所有 trace / log / metric 数据"
  confirm "确认继续?"
fi

# ---------- 1. Grafana ----------
echo "[1/6] 卸载 Grafana..."
if helm -n "${NAMESPACE}" status grafana >/dev/null 2>&1; then
  run helm -n "${NAMESPACE}" uninstall grafana
else
  echo "  (grafana release 不存在，跳过)"
fi
echo ""

# ---------- 2. Beyla ----------
echo "[2/6] 卸载 Beyla..."
if [ -f "${DIR}/beyla.yaml" ]; then
  run kubectl delete -f "${DIR}/beyla.yaml" -n "${NAMESPACE}" --ignore-not-found --wait=false
fi
echo ""

# ---------- 3. Alloy ----------
echo "[3/6] 卸载 Alloy..."
if [ -f "${DIR}/alloy.yaml" ]; then
  run kubectl delete -f "${DIR}/alloy.yaml" -n "${NAMESPACE}" --ignore-not-found --wait=false
fi
run kubectl -n "${NAMESPACE}" delete cm alloy-config --ignore-not-found
echo ""

# ---------- 4. Tempo ----------
echo "[4/6] 卸载 Tempo..."
if helm -n "${NAMESPACE}" status tempo >/dev/null 2>&1; then
  run helm -n "${NAMESPACE}" uninstall tempo
else
  echo "  (tempo release 不存在，跳过)"
fi
echo ""

# ---------- 5. MinIO ----------
echo "[5/6] 卸载 MinIO..."
if [ -f "${DIR}/minio.yaml" ]; then
  run kubectl delete -f "${DIR}/minio.yaml" -n "${NAMESPACE}" --ignore-not-found --wait=false
fi
echo ""

# ---------- 6. PVC / Namespace（仅 --purge）----------
if [ "$PURGE" = true ]; then
  echo "[6/6] 清理 PVC + Namespace..."

  # PVC 经常有 finalizer 卡住，先 patch 一下
  PVCS=$(kubectl -n "${NAMESPACE}" get pvc -o name 2>/dev/null || true)
  if [ -n "$PVCS" ]; then
    for pvc in $PVCS; do
      run kubectl -n "${NAMESPACE}" patch "$pvc" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done
    run kubectl -n "${NAMESPACE}" delete pvc --all --timeout=60s
  fi

  # namespace 也可能因为 finalizer 卡住
  run kubectl delete namespace "${NAMESPACE}" --ignore-not-found --timeout=60s
  echo ""
else
  echo "[6/6] 保留 PVC / Namespace（如需彻底清理，重跑 bash uninstall.sh --purge）"
  echo ""
  echo "  剩余 PVC:"
  kubectl -n "${NAMESPACE}" get pvc 2>/dev/null || echo "  (无)"
fi
echo ""

# ---------- 总结 + 手动清理提示 ----------
echo "========================================="
echo " 卸载完成"
echo "========================================="
echo ""
echo "当前 ${NAMESPACE} 命名空间状态:"
kubectl get all -n "${NAMESPACE}" 2>/dev/null || echo "  (namespace 已删除)"
echo ""

echo "需要手动检查 / 还原的内容："
echo ""
echo "1. kube-prometheus 中的 Prometheus CR 改动**没有自动还原**："
echo "     spec.otlp / spec.enableRemoteWriteReceiver / spec.enableFeatures[exemplar-storage]"
echo "   如果不再需要 OTLP 接收 / exemplar，编辑下面这个文件后重新 apply:"
echo "     kubernetes/prometheus/manifests/prometheus-prometheus.yaml"
echo ""
echo "2. Prometheus 为业务 namespace 建的 Role/RoleBinding (test/uat/default/kube-system/monitoring)"
echo "   保留即可（不影响其他工作负载）。如需清理:"
echo "     kubectl delete -f kubernetes/prometheus/manifests/prometheus-roleSpecificNamespaces.yaml"
echo "     kubectl delete -f kubernetes/prometheus/manifests/prometheus-roleBindingSpecificNamespaces.yaml"
echo ""
echo "3. Grafana datasource provisioning Secret 由 helm 管理，已随 grafana release 一起删除"
echo ""
echo "4. Tempo / MinIO 的 PVC 可能因 StorageClass 配置而未自动回收 PV，确认:"
echo "     kubectl get pv | grep -E 'tempo|minio'"
