#!/bin/bash
# 卸载 kube-prometheus 监控栈。
# 用法:
#   bash uninstall.sh              # 删除所有组件，保留 CRD + PVC
#   bash uninstall.sh --crd        # 同时删除 CRD (会级联删除所有 ServiceMonitor/PodMonitor/Rule)
#   bash uninstall.sh --purge      # 删除 CRD + PVC + monitoring namespace
#   bash uninstall.sh --dry-run    # 预演
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="${DIR}/manifests"
SETUP="${MANIFESTS}/setup"
DEL_CRD=false
PURGE=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --crd)     DEL_CRD=true ;;
    --purge)   DEL_CRD=true; PURGE=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# //'
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
echo " kube-prometheus 卸载"
echo "  manifests:  ${MANIFESTS}"
echo "  del-crd:    ${DEL_CRD}    (会级联删除所有自定义资源)"
echo "  purge:      ${PURGE}      (--purge 会删 PVC + namespace)"
echo "  dry-run:    ${DRY_RUN}"
echo "========================================="
echo ""

if [ "$DEL_CRD" = true ]; then
  echo "⚠️  --crd / --purge 模式会删除 CRD：所有 ServiceMonitor / PodMonitor"
  echo "    / Probe / PrometheusRule / Prometheus / Alertmanager CR 都会被一起清掉"
  echo "    （包括你为业务建的所有自定义 monitor）"
fi
if [ "$PURGE" = true ]; then
  echo "⚠️  --purge 模式会删除 PVC + monitoring namespace：历史指标数据**永久丢失**"
fi
if [ "$DEL_CRD" = true ] || [ "$PURGE" = true ]; then
  confirm "确认继续?"
fi

# ---------- 1. 主体组件 ----------
echo "[1/3] 卸载主体组件 (manifests/)..."
if [ -d "${MANIFESTS}" ]; then
  # --ignore-not-found 单步失败不阻塞
  run kubectl delete --ignore-not-found -f "${MANIFESTS}/"
else
  echo "  WARN: manifests 目录不存在，跳过"
fi
echo ""

# ---------- 2. CRD 和 namespace ----------
if [ "$DEL_CRD" = true ]; then
  echo "[2/3] 卸载 CRD 和 setup 资源..."
  if [ -d "${SETUP}" ]; then
    run kubectl delete --ignore-not-found -f "${SETUP}/"
  fi
else
  echo "[2/3] 保留 CRD（如需一并删除重跑 bash uninstall.sh --crd）"
fi
echo ""

# ---------- 3. PVC / Namespace（仅 --purge）----------
if [ "$PURGE" = true ]; then
  echo "[3/3] 清理 PVC + namespace..."

  PVCS=$(kubectl -n monitoring get pvc -o name 2>/dev/null || true)
  if [ -n "$PVCS" ]; then
    for pvc in $PVCS; do
      run kubectl -n monitoring patch "$pvc" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done
    run kubectl -n monitoring delete pvc --all --timeout=60s
  fi

  # monitoring namespace 可能还被 Loki 等其他组件用，慎删
  echo ""
  read -r -p "  是否同时删除 monitoring namespace? Loki 等其他组件也会被一起清掉 [y/N]: " del_ns
  if [[ "$del_ns" =~ ^[Yy]$ ]]; then
    run kubectl delete namespace monitoring --timeout=60s
  else
    echo "  保留 monitoring namespace"
  fi
else
  echo "[3/3] 保留 PVC / namespace（如需一并删除重跑 bash uninstall.sh --purge）"
  echo ""
  echo "  剩余 monitoring 命名空间 PVC:"
  kubectl -n monitoring get pvc 2>/dev/null || echo "  (无)"
fi
echo ""

echo "========================================="
echo " 卸载完成"
echo "========================================="
echo ""
echo "当前 monitoring 命名空间状态:"
kubectl get all -n monitoring 2>/dev/null || echo "  (namespace 已删除)"
echo ""

echo "注意："
echo "  - 业务侧创建的 ServiceMonitor/PodMonitor/Rule 在 CRD 删除时会一起没"
echo "  - 如果 Loki/其他组件也在 monitoring 命名空间，不要随便删 namespace"
echo "  - Grafana 的 dashboard 数据 (如果存在 PVC) 会被 --purge 删掉，提前导出 JSON 备份"
