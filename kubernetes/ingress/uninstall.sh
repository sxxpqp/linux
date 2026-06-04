#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — 卸载 ingress-nginx DaemonSet
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/ingress/uninstall.sh
# 用法: bash uninstall.sh [选项]
#
# 反向删除 install.sh + deploy.yaml 装的所有资源,默认 dry-run

set -euo pipefail

APPLY="false"
REMOVE_LABELS="false"

usage() {
  cat <<'EOF'
用法: bash uninstall.sh [选项]

默认 dry-run。加 --apply 才真删。

选项:
  --apply             真执行
  --remove-labels     同时去掉节点 ingress=true 标签
  -h, --help          显示帮助

示例:
  bash uninstall.sh                      # dry-run 看计划
  bash uninstall.sh --apply              # 真删
  bash uninstall.sh --apply --remove-labels  # 删 + 去标签
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="true" ;;
    --remove-labels) REMOVE_LABELS="true" ;;
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
DEPLOY_YAML="${SCRIPT_DIR}/deploy.yaml"

# ============================================================
# 1/4 前置检查
# ============================================================
log "[1/4] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }

if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
  ok "ingress-nginx namespace 不存在,已经卸载干净"
  exit 0
fi

[ "$APPLY" != "true" ] && warn "DRY-RUN 模式,只打印不执行"

# ============================================================
# 2/4 删资源(分步删,先杀 DS 再清 ns,避免卡 Terminating)
# ============================================================
log "[2/4] 删 ingress-nginx 资源"

# 先删 webhook(backend 已死后会拦后续 API)
if [ "$APPLY" = "true" ]; then
  kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found --wait=false 2>/dev/null || true
fi

# 先删 DS 让 Pod 停掉(否则 Pod 还在跑时删 ns 会超时)
if kubectl -n ingress-nginx get ds ingress-nginx-controller >/dev/null 2>&1; then
  run "kubectl -n ingress-nginx delete ds ingress-nginx-controller --ignore-not-found --timeout=60s"
fi

# 等 Pod 终止
if [ "$APPLY" = "true" ] && kubectl -n ingress-nginx get pods --no-headers 2>/dev/null | grep -qv Completed; then
  log "  等 Pod 终止(最多 30s)..."
  kubectl -n ingress-nginx wait --for=delete pod --all --timeout=30s 2>/dev/null || \
    kubectl -n ingress-nginx delete pods --all --force --grace-period=0 --wait=false 2>/dev/null || true
fi

# 再删其余资源(namespace 最后,放步骤 3 单独处理)
if [ -f "$DEPLOY_YAML" ]; then
  # 用 kubectl delete -f 但排除 Namespace(它排第一个,删了就会卡 Pod 终止)
  run "kubectl delete -f $DEPLOY_YAML --ignore-not-found --timeout=60s"
else
  warn "deploy.yaml 不在,手动删: kubectl delete ns ingress-nginx --force"
fi

# ============================================================
# 3/4 清理 namespace
# ============================================================
log "[3/4] 清理 ingress-nginx namespace"

if [ "$APPLY" = "true" ] && kubectl get ns ingress-nginx >/dev/null 2>&1; then
  warn "namespace 还在,强清(Pod + finalizer)"
  kubectl -n ingress-nginx delete pods --all --force --grace-period=0 --wait=false 2>/dev/null || true
  sleep 3
  kubectl patch ns ingress-nginx --type=json \
    -p '[{"op":"remove","path":"/spec/finalizers"}]' 2>/dev/null || \
  kubectl get ns ingress-nginx -o json 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null | \
    kubectl replace --raw "/api/v1/namespaces/ingress-nginx/finalize" -f - 2>/dev/null || true
  sleep 2
fi

if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
  ok "ingress-nginx 已卸载干净"
else
  warn "ingress-nginx namespace 仍在(可能 Terminating),稍后手动: kubectl delete ns ingress-nginx --force"
fi

# 清理残留 webhook(首次删不干净时再扫一次)
if [ "$APPLY" = "true" ]; then
  kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found 2>/dev/null || true
fi

# ============================================================
# 4/4 节点标签(可选)
# ============================================================
log "[4/4] 节点标签"

if [ "$REMOVE_LABELS" = "true" ]; then
  LABELED=$(kubectl get nodes -l ingress=true -o name 2>/dev/null)
  if [ -n "$LABELED" ]; then
    for node in $LABELED; do
      run "kubectl label $node ingress-"
    done
  else
    ok "没有节点含 ingress=true 标签"
  fi
else
  warn "节点标签保留(加 --remove-labels 去掉)"
  kubectl get nodes -l ingress=true -o custom-columns='NAME:.metadata.name' --no-headers 2>/dev/null | sed 's/^/    /' || true
fi

log "==== 完成 ===="

[ "$APPLY" != "true" ] && warn "以上是 DRY-RUN,确认后跑: bash $0 --apply"
