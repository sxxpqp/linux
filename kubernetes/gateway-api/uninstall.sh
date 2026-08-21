#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — 卸载 Gateway API CRD + NGINX Gateway Fabric
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/gateway-api/uninstall.sh
# 用法: curl -sL <URL> -o uninstall.sh && bash uninstall.sh [选项]

set -euo pipefail

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

GATEWAY_API_VERSION="v1.4.0"
NGF_VERSION="v2.4.2"
REMOVE_EXPERIMENTAL="false"
KEEP_CRDS="false"
APPLY="false"
WAIT_TIMEOUT="180s"

usage() {
  cat <<'EOF'
用法: bash uninstall.sh [选项]

默认 dry-run。加 --apply 才真删。

选项:
  --apply                     真执行
  --gateway-api-version=VER   Gateway API CRD 版本,默认 v1.4.0
  --ngf-version=VER           NGINX Gateway Fabric 版本,默认 v2.6.7
  --remove-experimental       同时删除 Gateway API experimental CRD
  --keep-crds                 只卸载 NGF,保留 Gateway API CRD
  --wait-timeout=180s         等待删除超时,默认 180s
  -h, --help                  显示帮助

示例:
  bash uninstall.sh
  bash uninstall.sh --apply
  bash uninstall.sh --apply --keep-crds
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="true" ;;
    --gateway-api-version=*) GATEWAY_API_VERSION="${1#*=}" ;;
    --ngf-version=*) NGF_VERSION="${1#*=}" ;;
    --remove-experimental) REMOVE_EXPERIMENTAL="true" ;;
    --keep-crds) KEEP_CRDS="true" ;;
    --wait-timeout=*) WAIT_TIMEOUT="${1#*=}" ;;
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

GATEWAY_STANDARD_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
GATEWAY_EXPERIMENTAL_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
NGF_CRDS_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/nginx/nginx-gateway-fabric/${NGF_VERSION}/deploy/crds.yaml"
NGF_DEPLOY_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/nginx/nginx-gateway-fabric/${NGF_VERSION}/deploy/default/deploy.yaml"

log "[1/4] 前置检查"
command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
ok "kubectl 可用"
[ "$APPLY" != "true" ] && warn "DRY-RUN 模式,只打印不执行"

log "[2/4] 卸载 NGINX Gateway Fabric"
if [ "$APPLY" = "true" ]; then
  kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null | grep -i 'nginx-gateway' | xargs -r kubectl delete --wait=false 2>/dev/null || true
fi
run "kubectl delete -f $NGF_DEPLOY_URL --ignore-not-found --timeout=$WAIT_TIMEOUT"
run "kubectl delete -f $NGF_CRDS_URL --ignore-not-found --timeout=$WAIT_TIMEOUT"

if [ "$APPLY" = "true" ] && kubectl get ns nginx-gateway >/dev/null 2>&1; then
  if kubectl -n nginx-gateway get pods --no-headers 2>/dev/null | grep -q .; then
    log "  等 nginx-gateway namespace 下 Pod 终止(最多 30s)..."
    kubectl -n nginx-gateway wait --for=delete pod --all --timeout=30s 2>/dev/null || true
  fi
fi

log "[3/4] 卸载 Gateway API CRD"
if [ "$KEEP_CRDS" = "true" ]; then
  warn "按参数保留 Gateway API CRD"
else
  if [ "$REMOVE_EXPERIMENTAL" = "true" ]; then
    run "kubectl delete -f $GATEWAY_EXPERIMENTAL_URL --ignore-not-found --timeout=$WAIT_TIMEOUT"
  fi
  run "kubectl delete -f $GATEWAY_STANDARD_URL --ignore-not-found --timeout=$WAIT_TIMEOUT"
fi

log "[4/4] 验证"
if [ "$APPLY" = "true" ]; then
  kubectl get gatewayclass 2>/dev/null || true
  kubectl get crd | grep 'gateway.networking.k8s.io' || true
fi

echo
log "==== 完成 ===="
if [ "$APPLY" != "true" ]; then
  warn "以上是 DRY-RUN,确认后跑: bash $0 --apply"
fi
