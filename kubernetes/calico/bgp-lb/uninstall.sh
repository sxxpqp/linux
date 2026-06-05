#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — 卸载 Calico BGP + LB 模式
set -euo pipefail

APPLY="false"
CALICO_VERSION="v3.28.2"

usage() {
  cat <<'EOF'
用法: bash uninstall.sh [选项]
默认 dry-run。加 --apply 才真删。
选项: --apply | -h, --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: $1" >&2; usage >&2; exit 1 ;;
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

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }

if ! kubectl get ns tigera-operator >/dev/null 2>&1 && \
   ! kubectl get ns calico-system >/dev/null 2>&1; then
  ok "Calico 已卸载干净"; exit 0
fi

[ "$APPLY" != "true" ] && warn "DRY-RUN 模式"

log "删 Installation / APIServer CR"

if [ "$APPLY" = "true" ]; then
  for cr in apiserver installation; do
    kubectl patch $cr default --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
fi
run "kubectl delete apiserver default --ignore-not-found --timeout=30s"
run "kubectl delete installation default --ignore-not-found --timeout=30s"

log "清理 namespace"

force_clear_ns() {
  local ns="$1"
  [ "$APPLY" != "true" ] && return
  kubectl get ns "$ns" >/dev/null 2>&1 || return
  kubectl -n "$ns" delete pods --all --force --grace-period=0 --wait=false 2>/dev/null || true
  sleep 2
  kubectl get ns "$ns" -o json 2>/dev/null | \
    python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null | \
    kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
}

force_clear_ns "calico-system"
force_clear_ns "calico-apiserver"
ok "namespace 已清理"

log "删 ConfigMap + tigera-operator"

run "kubectl -n tigera-operator delete cm kubernetes-services-endpoint --ignore-not-found"
kubectl -n tigera-operator scale deploy tigera-operator --replicas=0 --timeout=30s 2>/dev/null || true

NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"
TIGERA_OP_URL="${NEXUS_RAW}/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
TMP_OP=$(mktemp /tmp/tigera-operator.XXXXXX.yaml)
trap "rm -f $TMP_OP" EXIT

if curl -fsSLk "$TIGERA_OP_URL" -o "$TMP_OP" 2>/dev/null; then
  run "kubectl delete -f $TMP_OP --ignore-not-found --timeout=180s"
fi

run "kubectl delete clusterrole calico-kube-controllers calico-node calico-cni-plugin --ignore-not-found --wait=false 2>/dev/null"
run "kubectl delete clusterrolebinding calico-kube-controllers calico-node calico-cni-plugin --ignore-not-found --wait=false 2>/dev/null"

force_clear_ns "tigera-operator"

log "残留检查"
LEFTOVER=""
for cr in installation apiserver; do kubectl get $cr default >/dev/null 2>&1 && LEFTOVER="$LEFTOVER $cr"; done
for ns in calico-system tigera-operator calico-apiserver; do kubectl get ns $ns >/dev/null 2>&1 && LEFTOVER="$LEFTOVER ns/$ns"; done
[ -z "$LEFTOVER" ] && ok "无残留" || warn "残留:$LEFTOVER"

log "==== 完成 ===="
[ "$APPLY" != "true" ] && warn "确认: bash $0 --apply"
