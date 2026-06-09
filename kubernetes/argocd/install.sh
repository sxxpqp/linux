#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — ArgoCD v2.13.3(K8s 1.28 默认)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/argocd/install.sh
# 用法: curl -sL <URL> -o install.sh && bash install.sh [选项]
#
# 默认装 install-v2.13.3.yaml(K8s 1.28 - 1.31 兼容窗口)。
# 镜像 quay.io / ghcr.io / docker.io 均走节点 containerd mirror,YAML 一个字不改。
# 大版本兼容矩阵 / 升级路径 / Ingress 暴露 / 第一个 Application 见 ./README.md

set -euo pipefail

NAMESPACE="argocd"
YAML=""
SERVICE_TYPE=""    # 空 = 用 yaml 默认(ClusterIP)
DRY_RUN="false"
NO_WAIT="false"

usage() {
  cat <<'EOF'
用法: bash install.sh [选项]

可选:
  --namespace=NS         安装 namespace,默认 argocd(改 ns 会破 RBAC,不建议)
  --yaml=PATH            install yaml 路径,默认 ./install-v2.13.3.yaml
                         集群升 K8s 1.30+ 后可换 ./arglcdinstall.yaml(v3.3.0)
  --service-type=TYPE    覆盖 argocd-server Service 类型:
                         ClusterIP(默认,port-forward / Ingress 暴露)
                         NodePort(内网快速暴露)
                         LoadBalancer(配合 Calico BGP-LB / MetalLB)
  --no-wait              跳过 rollout 等待(yaml 装完立刻返回)
  --dry-run              只检查不 apply
  -h, --help             显示帮助

示例:
  # 默认安装(ClusterIP,port-forward 暴露)
  bash install.sh

  # 内网快速暴露
  bash install.sh --service-type=NodePort

  # 配合 Calico BGP-LB / MetalLB 拿外部 IP
  bash install.sh --service-type=LoadBalancer

  # 集群升 1.30+ 后切 v3.3.0
  bash install.sh --yaml=./arglcdinstall.yaml
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace=*) NAMESPACE="${1#*=}" ;;
    --yaml=*) YAML="${1#*=}" ;;
    --service-type=*) SERVICE_TYPE="${1#*=}" ;;
    --dry-run) DRY_RUN="true" ;;
    --no-wait) NO_WAIT="true" ;;
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -z "$YAML" ] && YAML="${SCRIPT_DIR}/install-v2.13.3.yaml"
[[ "$YAML" != /* ]] && YAML="${SCRIPT_DIR}/${YAML}"

# ============================================================
# 1/5 前置检查
# ============================================================
log "[1/5] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
ok "kubectl 可用"

if [ ! -f "$YAML" ]; then
  err "install yaml 不存在: $YAML"
  exit 1
fi
ok "install yaml: $YAML ($(wc -l < "$YAML") 行)"

# K8s 版本兼容性提醒
K8S_SERVER=$(kubectl version -o json 2>/dev/null | \
  grep -oE '"gitVersion":[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | \
  grep -oE 'v[0-9]+\.[0-9]+' | head -1 || true)
if [ -n "$K8S_SERVER" ]; then
  ok "K8s 版本: $K8S_SERVER"
  case "$YAML" in
    *install-v2.13*)
      case "$K8S_SERVER" in
        v1.28|v1.29|v1.30|v1.31) ;;
        *) warn "ArgoCD v2.13.x 官方兼容 K8s 1.28-1.31,你是 $K8S_SERVER(可继续,出问题官方不背书)" ;;
      esac
      ;;
    *arglcdinstall*|*v3*)
      case "$K8S_SERVER" in
        v1.31|v1.32|v1.33) ;;
        *) warn "ArgoCD v3.3.x 兼容 K8s 1.31-1.33,你是 $K8S_SERVER(K8s 1.28 请用 install-v2.13.3.yaml)" ;;
      esac
      ;;
  esac
fi

# 镜像 mirror 提醒(本机视角,只是提示)
MISSING_MIRROR=""
for h in quay.io ghcr.io docker.io; do
  [ ! -f "/etc/containerd/certs.d/$h/hosts.toml" ] && MISSING_MIRROR="$MISSING_MIRROR $h"
done
if [ -n "$MISSING_MIRROR" ]; then
  warn "本机未配 mirror:$MISSING_MIRROR"
  warn "  集群节点若也没配,Pod 会 ImagePullBackOff。每节点跑:bash ../../docker/containerd/mirrors.sh"
fi

# 旧安装检测
if kubectl -n "$NAMESPACE" get sts argocd-application-controller >/dev/null 2>&1; then
  CUR_VER=$(kubectl -n "$NAMESPACE" get sts argocd-application-controller \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | awk -F: '{print $NF}')
  warn "ArgoCD 已装在 ns/$NAMESPACE,当前镜像 tag=$CUR_VER,脚本会走 apply 幂等(可能触发滚动升级)"
fi

# ============================================================
# 2/5 namespace
# ============================================================
log "[2/5] namespace"

if kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  ok "namespace 已存在: $NAMESPACE"
else
  if [ "$DRY_RUN" = "true" ]; then
    warn "[dry-run] kubectl create namespace $NAMESPACE"
  else
    kubectl create namespace "$NAMESPACE"
    ok "namespace 已建: $NAMESPACE"
  fi
fi

# ============================================================
# 3/5 apply install yaml
# ============================================================
log "[3/5] apply install yaml"

if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] kubectl apply -n $NAMESPACE -f $YAML"
  [ -n "$SERVICE_TYPE" ] && warn "[dry-run] patch svc argocd-server type=$SERVICE_TYPE"
else
  # CRD 在 yaml 顶部,kubectl 会按顺序处理(先 CRD 再 controller),不需要分两次 apply
  kubectl apply -n "$NAMESPACE" -f "$YAML"
  ok "install yaml 已 apply"

  if [ -n "$SERVICE_TYPE" ]; then
    log "  覆盖 argocd-server Service.type → $SERVICE_TYPE"
    kubectl -n "$NAMESPACE" patch svc argocd-server \
      --type=merge -p "{\"spec\":{\"type\":\"$SERVICE_TYPE\"}}"
    ok "argocd-server Service.type=$SERVICE_TYPE"
  fi
fi

# ============================================================
# 4/5 等组件 ready
# ============================================================
log "[4/5] 等组件 ready"

if [ "$DRY_RUN" = "true" ] || [ "$NO_WAIT" = "true" ]; then
  warn "跳过等待($([ "$DRY_RUN" = "true" ] && echo dry-run || echo --no-wait))"
else
  log "  等 argocd-application-controller StatefulSet..."
  kubectl -n "$NAMESPACE" rollout status sts/argocd-application-controller --timeout=300s
  ok "argocd-application-controller ready"

  log "  等 6 个 Deployment available..."
  kubectl -n "$NAMESPACE" wait --for=condition=available deploy --all --timeout=300s
  ok "全部 Deployment available"
fi

# ============================================================
# 5/5 输出登录 / 入口信息
# ============================================================
log "[5/5] 登录 / 入口信息"

if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] 跳过"
  exit 0
fi

kubectl -n "$NAMESPACE" get pod

PASSWORD=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

SVC_TYPE=$(kubectl -n "$NAMESPACE" get svc argocd-server \
  -o jsonpath='{.spec.type}' 2>/dev/null || echo "ClusterIP")

echo
log "==== 安装完成 ===="
echo
echo "登录:"
echo "  用户: admin"
if [ -n "$PASSWORD" ]; then
  echo "  密码: $PASSWORD"
  echo "  ⚠ 初始密码,登入后立即改 + 删 secret:"
  echo "    kubectl -n $NAMESPACE delete secret argocd-initial-admin-secret"
else
  warn "  argocd-initial-admin-secret 未取到(可能 server 还没初始化完,稍后再查)"
fi
echo
echo "访问 UI:"
case "$SVC_TYPE" in
  LoadBalancer)
    LB_IP=$(kubectl -n "$NAMESPACE" get svc argocd-server \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$LB_IP" ]; then
      echo "  https://$LB_IP   (LoadBalancer 已分配)"
    else
      warn "  Service=LoadBalancer 但 EXTERNAL-IP <pending>"
      echo "    检查 Calico BGP-LB / MetalLB 是否装,或回退:"
      echo "    bash install.sh --service-type=NodePort"
    fi
    ;;
  NodePort)
    NP=$(kubectl -n "$NAMESPACE" get svc argocd-server \
      -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}')
    NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<节点IP>")
    echo "  https://$NODE_IP:$NP"
    ;;
  *)
    echo "  kubectl -n $NAMESPACE port-forward svc/argocd-server 8080:443"
    echo "  → https://localhost:8080"
    ;;
esac
echo
echo "Ingress 暴露(配合 ingress-nginx)见 README 模式 D 段"
echo
echo "验证:  bash $(dirname "$0")/test.sh"
echo "卸载:  bash $(dirname "$0")/uninstall.sh --apply"
