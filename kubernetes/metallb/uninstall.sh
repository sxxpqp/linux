#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — 卸载 MetalLB
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/metallb/uninstall.sh
# 用法: bash uninstall.sh [选项]
#
# 默认 dry-run,加 --apply 才真删

set -euo pipefail

APPLY="false"
VERSION="${VERSION:-v0.14.8}"
NS="metallb-system"

usage() {
  cat <<'EOF'
用法: bash uninstall.sh [选项]

默认 dry-run。加 --apply 才真删。

选项:
  --apply             真执行
  -h, --help          显示帮助

示例:
  bash uninstall.sh            # dry-run 看计划
  bash uninstall.sh --apply    # 真删
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

run() {
  if [ "$APPLY" = "true" ]; then
    echo -e "  ${GREEN}\$${NC} $*"
    eval "$@"
  else
    echo -e "  ${YELLOW}[dry-run]${NC} $*"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_LOCAL="${SCRIPT_DIR}/metallb-native.yaml"
NATIVE_URL="https://nexus.ihome.sxxpqp.top:8443/metallb/metallb/${VERSION}/config/manifests/metallb-native.yaml"

if [ -f "${NATIVE_LOCAL}" ]; then
  NATIVE_SRC="${NATIVE_LOCAL}"
else
  NATIVE_SRC="${NATIVE_URL}"
fi

# ============================================================
# 前置检查
# ============================================================
log "前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }

if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  ok "metallb-system namespace 不存在,已经卸载干净"
  exit 0
fi

[ "$APPLY" != "true" ] && warn "DRY-RUN 模式,只打印不执行"

# ============================================================
# 删 CR + native 清单
# ============================================================
log "删 IPAddressPool / L2Advertisement"
run "kubectl delete -f ${SCRIPT_DIR}/pool.yaml --ignore-not-found --timeout=30s"
run "kubectl delete -f ${SCRIPT_DIR}/bgp.yaml --ignore-not-found --timeout=30s 2>/dev/null"

log "删 MetalLB 主体(源: ${NATIVE_SRC})"
run "kubectl delete -f ${NATIVE_SRC} --ignore-not-found --timeout=120s"

# ============================================================
# 清理 namespace
# ============================================================
log "清理 metallb-system namespace"

if [ "$APPLY" = "true" ] && kubectl get ns "${NS}" >/dev/null 2>&1; then
  warn "namespace 还在,强清"
  kubectl -n "${NS}" delete pods --all --force --grace-period=0 --wait=false 2>/dev/null || true
  sleep 2
  kubectl patch ns "${NS}" --type=json \
    -p '[{"op":"remove","path":"/spec/finalizers"}]' 2>/dev/null || \
  kubectl get ns "${NS}" -o json 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null | \
    kubectl replace --raw "/api/v1/namespaces/${NS}/finalize" -f - 2>/dev/null || true
  sleep 2
fi

if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  ok "metallb-system 已卸载干净"
else
  warn "metallb-system namespace 仍在,稍后手动: kubectl delete ns ${NS} --force"
fi

# ============================================================
# CRD 残留检查
# ============================================================
log "CRD 残留检查"
CRD_COUNT=$(kubectl get crd --no-headers 2>/dev/null | grep -c metallb.io || true)
if [ "${CRD_COUNT:-0}" -eq 0 ]; then
  ok "无 metallb CRD 残留"
else
  warn "${CRD_COUNT} 个 metallb CRD 残留,稍后手动: kubectl get crd | grep metallb.io | awk '{print \$1}' | xargs -r kubectl delete crd"
fi

log "==== 完成 ===="

[ "$APPLY" != "true" ] && warn "以上是 DRY-RUN,确认后跑: bash $0 --apply"
