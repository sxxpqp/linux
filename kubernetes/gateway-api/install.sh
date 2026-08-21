#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — 安装 Gateway API CRD + NGINX Gateway Fabric
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/gateway-api/install.sh
# 用法: curl -sL <URL> -o install.sh && bash install.sh [选项]
# 支持k8s >=1.28
set -euo pipefail

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

GATEWAY_API_VERSION="v1.4.0"
NGF_VERSION="v2.4.2"
INSTALL_EXPERIMENTAL="false"
SKIP_NGF="false"
DRY_RUN="false"
WAIT_TIMEOUT="300s"

usage() {
  cat <<'EOF'
用法: bash install.sh [选项]

默认安装:
  1) Gateway API standard CRD
  2) NGINX Gateway Fabric

选项:
  --gateway-api-version=VER   Gateway API CRD 版本,默认 v1.4.0
  --ngf-version=VER           NGINX Gateway Fabric 版本,默认 v2.6.7
  --experimental              额外安装 Gateway API experimental CRD(TCP/UDP/TLS/GRPC 等)
  --skip-ngf                  只装 Gateway API CRD,不装控制器
  --dry-run                   只打印计划,不执行
  --wait-timeout=300s         等待控制器 ready 的超时,默认 300s
  -h, --help                  显示帮助

示例:
  bash install.sh
  bash install.sh --experimental
  bash install.sh --skip-ngf
  bash install.sh --gateway-api-version=v1.4.0 --ngf-version=v2.6.7
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --gateway-api-version=*) GATEWAY_API_VERSION="${1#*=}" ;;
    --ngf-version=*) NGF_VERSION="${1#*=}" ;;
    --experimental) INSTALL_EXPERIMENTAL="true" ;;
    --skip-ngf) SKIP_NGF="true" ;;
    --dry-run) DRY_RUN="true" ;;
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
  if [ "$DRY_RUN" = "true" ]; then
    echo -e "  ${YELLOW}[dry-run]${NC} $*"
  else
    echo -e "  ${GREEN}\$${NC} $*"
    eval "$@"
  fi
}

GATEWAY_STANDARD_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
GATEWAY_EXPERIMENTAL_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/experimental-install.yaml"
NGF_CRDS_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/nginx/nginx-gateway-fabric/${NGF_VERSION}/deploy/crds.yaml"
NGF_DEPLOY_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/nginx/nginx-gateway-fabric/${NGF_VERSION}/deploy/default/deploy.yaml"

log "[1/5] 前置检查"
command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
ok "kubectl 可用"

if kubectl get gatewayclass >/dev/null 2>&1; then
  ok "集群已支持 gateway.networking.k8s.io API"
else
  warn "当前还没装 Gateway API CRD,脚本会先安装"
fi

if kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null | grep -qi 'nginx-gateway\|gateway-api'; then
  warn "检测到现有 gateway-api / nginx-gateway 相关 webhook,如曾卸载不干净需先排查"
fi

if [ "$DRY_RUN" = "true" ]; then
  warn "DRY-RUN 模式,只打印不执行"
fi

log "[2/5] 安装 Gateway API CRD"
run "kubectl apply -f $GATEWAY_STANDARD_URL"
if [ "$INSTALL_EXPERIMENTAL" = "true" ]; then
  run "kubectl apply -f $GATEWAY_EXPERIMENTAL_URL"
  ok "已包含 experimental CRD"
else
  ok "只安装 standard CRD"
fi

log "[3/5] 安装 NGINX Gateway Fabric"
if [ "$SKIP_NGF" = "true" ]; then
  warn "按参数跳过 NGF 控制器安装"
else
  run "kubectl apply --server-side -f $NGF_CRDS_URL"
  run "kubectl apply -f $NGF_DEPLOY_URL"
  ok "NGF CRD 已用 server-side apply,控制器 YAML 已 apply"
fi

log "[4/5] 等待控制器 ready"
if [ "$DRY_RUN" = "true" ] || [ "$SKIP_NGF" = "true" ]; then
  warn "跳过等待"
else
  DEPLOYS=$(kubectl -n nginx-gateway get deploy -o name 2>/dev/null || true)
  if [ -n "$DEPLOYS" ]; then
    for deploy in $DEPLOYS; do
      kubectl -n nginx-gateway rollout status "$deploy" --timeout="$WAIT_TIMEOUT"
    done
    ok "nginx-gateway namespace 下 Deployment 已 ready"
  else
    warn "nginx-gateway namespace 下没找到 Deployment,请手动检查: kubectl -n nginx-gateway get all"
  fi
fi

log "[5/5] 验证"
if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] 跳过验证"
  exit 0
fi

kubectl get gatewayclass || true
if [ "$SKIP_NGF" != "true" ]; then
  kubectl -n nginx-gateway get pods -o wide || true
fi

echo
log "==== 安装完成 ===="
echo "常用验证:"
echo "  kubectl get gatewayclass"
echo "  kubectl -n nginx-gateway get pods -o wide"
echo "  kubectl get gateways.gateway.networking.k8s.io -A"
echo "  kubectl get httproute -A"
echo
echo "示例:"
echo "  kubectl apply -f $(dirname \"$0\")/examples/01-gateway.yaml"
echo "  kubectl apply -f $(dirname \"$0\")/examples/02-httproute-basic.yaml"
echo
echo "卸载:"
echo "  bash $(dirname \"$0\")/uninstall.sh --apply"
