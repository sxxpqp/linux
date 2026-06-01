#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/loki/uninstall.sh
# 卸载 Loki。
# 用法:
#   bash uninstall.sh             # 保留 PVC（历史日志）
#   bash uninstall.sh --purge     # 同时删除 PVC（日志丢失）
#   bash uninstall.sh --dry-run   # 预演
set -uo pipefail

NAMESPACE="monitoring"
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
echo " Loki 卸载"
echo "  namespace: ${NAMESPACE}"
echo "  purge:     ${PURGE}"
echo "  dry-run:   ${DRY_RUN}"
echo "========================================="
echo ""

if [ "$PURGE" = true ]; then
  echo "⚠️  --purge 模式会删除 PVC，所有历史日志丢失"
  confirm "确认继续?"
fi

# 1. Loki Helm release
echo "[1/3] 卸载 Loki helm release..."
if helm -n "${NAMESPACE}" status loki >/dev/null 2>&1; then
  run helm -n "${NAMESPACE}" uninstall loki
else
  echo "  (loki release 不存在，跳过)"
fi
echo ""

# 2. Promtail（如果用了 promtail 而不是 alloy）
echo "[2/3] 检查并卸载 Promtail（若安装了）..."
if helm -n "${NAMESPACE}" status promtail >/dev/null 2>&1; then
  run helm -n "${NAMESPACE}" uninstall promtail
else
  echo "  (没有 promtail release，跳过 —— 你可能用的是 Alloy)"
fi
echo ""

# 3. PVC 清理（仅 --purge）
if [ "$PURGE" = true ]; then
  echo "[3/3] 清理 Loki PVC..."
  PVCS=$(kubectl -n "${NAMESPACE}" get pvc -l app.kubernetes.io/name=loki -o name 2>/dev/null || true)
  if [ -n "$PVCS" ]; then
    for pvc in $PVCS; do
      run kubectl -n "${NAMESPACE}" patch "$pvc" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    done
    run kubectl -n "${NAMESPACE}" delete pvc -l app.kubernetes.io/name=loki --timeout=60s
  else
    echo "  (没找到 Loki PVC)"
  fi
else
  echo "[3/3] 保留 PVC（如需清理重跑 bash uninstall.sh --purge）"
  echo ""
  echo "  剩余 Loki PVC:"
  kubectl -n "${NAMESPACE}" get pvc -l app.kubernetes.io/name=loki 2>/dev/null || echo "  (无)"
fi
echo ""

echo "========================================="
echo " 卸载完成"
echo "========================================="
echo ""
echo "注意："
echo "  - monitoring 命名空间没有删除（很可能 Prometheus 还在用）"
echo "  - 如果用外部 S3 存储，桶里的对象**不会自动清理**，需要在 S3 端手动删除"
