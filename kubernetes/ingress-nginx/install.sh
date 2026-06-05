#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — ingress-nginx v1.15.1 DaemonSet + hostNetwork + LoadBalancer
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/ingress-nginx/install.sh
# 用法: curl -sL <URL> -o install.sh && bash install.sh [选项]
#
# 生产默认 ✓+✓:hostNetwork=true(节点 80/443 直绑)+ Service LoadBalancer(配 Calico BGP-LB 拿单 VIP + ECMP)
#   - 配套 ../calico/bgp-lb/ 装好 → 路由器 ECMP 多路径分流到多 ingress 节点 → 本机终结
#   - 没装 BGP-LB:加 --service-type=NodePort,纯 hostNetwork 模式(节点 IP:80 入口)
# 改造思路详见 deploy-guide.md

set -euo pipefail

INGRESS_VERSION="v1.15.1"
LABEL_NODES=""
SERVICE_TYPE=""          # 空 = 用 deploy.yaml 默认(LoadBalancer);可改 NodePort
DRY_RUN="false"

usage() {
  cat <<'EOF'
用法: bash install.sh [选项]

可选:
  --label-nodes=N1,N2       打 ingress=true 标签的节点(逗号分隔)
  --label-nodes=all          所有 linux worker 节点都打标签
  --service-type=TYPE        覆盖 Service.type,默认走 deploy.yaml 的 LoadBalancer
                             可选 LoadBalancer / NodePort / ClusterIP
                             没装 Calico BGP-LB / 公有云 LB → 用 NodePort
  --dry-run                  只检查不打标签不 apply
  -h, --help                 显示帮助

示例:
  # 生产默认:hostNetwork + BGP-LB(LB IP + ECMP)
  bash install.sh --label-nodes=node1,node2

  # 没装 BGP-LB:纯 hostNetwork 模式(DNS 轮询节点 IP)
  bash install.sh --label-nodes=node1,node2 --service-type=NodePort

  # 节点已打好标签,直接装
  bash install.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --label-nodes=*) LABEL_NODES="${1#*=}" ;;
    --service-type=*) SERVICE_TYPE="${1#*=}" ;;
    --dry-run) DRY_RUN="true" ;;
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
DEPLOY_YAML="${SCRIPT_DIR}/deploy.yaml"

# ============================================================
# 1/5 前置检查
# ============================================================
log "[1/5] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
ok "kubectl 可用"

if [ ! -f "$DEPLOY_YAML" ]; then
  err "deploy.yaml 不在脚本同目录: $DEPLOY_YAML"
  exit 1
fi
ok "deploy.yaml: $DEPLOY_YAML ($(wc -l < "$DEPLOY_YAML") 行)"

# 检查是否有旧 ingress-nginx
if kubectl get ns ingress-nginx >/dev/null 2>&1; then
  if kubectl -n ingress-nginx get ds ingress-nginx-controller >/dev/null 2>&1; then
    warn "ingress-nginx 已安装(kubectl -n ingress-nginx get ds),脚本将走 apply 幂等"
  fi
fi

# 检测 Calico BGP-LB(deploy.yaml 默认 Service type=LoadBalancer,没 BGP-LB 会 pending)
HAS_BGPLB=false
if kubectl -n kube-system get deploy lb-assigner >/dev/null 2>&1; then
  HAS_BGPLB=true
  ok "检测到 Calico BGP-LB(lb-assigner Deployment 在),Service LoadBalancer 会自动分配 LB IP"
elif kubectl get deploy -A 2>/dev/null | grep -q metallb-controller; then
  HAS_BGPLB=true
  ok "检测到 MetalLB,Service LoadBalancer 会自动分配 LB IP"
else
  # 没装 LB controller,且用户没指定 --service-type — 只警告,不中止
  if [ -z "$SERVICE_TYPE" ]; then
    warn "未检测到 Calico BGP-LB / MetalLB / 云 LB Controller"
    warn "  → Service type=LoadBalancer 会一直 pending(hostNetwork 模式不影响 80/443 直绑)"
    warn "  → 想要 LB IP:bash ../calico/bgp-lb/install.sh --apiserver-host=<IP> --my-asn=64500 --lb-cidr=<CIDR>"
    warn "  → 想要 NodePort:重跑加 --service-type=NodePort"
  fi
fi

# ============================================================
# 2/5 节点标签
# ============================================================
log "[2/5] 节点标签"

LABELED=$(kubectl get nodes -l ingress=true -o name 2>/dev/null | wc -l)
if [ "$LABELED" -gt 0 ]; then
  ok "已有 $LABELED 个节点打了 ingress=true 标签:"
  kubectl get nodes -l ingress=true -o custom-columns='NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address' --no-headers 2>/dev/null | sed 's/^/    /'
fi

if [ -n "$LABEL_NODES" ]; then
  if [ "$LABEL_NODES" = "all" ]; then
    for node in $(kubectl get nodes -l 'node-role.kubernetes.io/control-plane!' -l 'node-role.kubernetes.io/master!' -o name --no-headers 2>/dev/null); do
      log "  打标签 $node ingress=true"
      [ "$DRY_RUN" != "true" ] && kubectl label "$node" ingress=true --overwrite >/dev/null 2>&1 || true
    done
  else
    IFS=',' read -ra NODES <<< "$LABEL_NODES"
    for n in "${NODES[@]}"; do
      log "  打标签 node/$n ingress=true"
      [ "$DRY_RUN" != "true" ] && kubectl label node "$n" ingress=true --overwrite >/dev/null 2>&1 || true
    done
  fi
elif [ "$LABELED" -eq 0 ]; then
  warn "没有节点打 ingress=true 标签,DaemonSet 不会调度任何 Pod!"
  warn "  → 运行: bash install.sh --label-nodes=node1,node2"
  warn "  → 或手动: kubectl label node <NAME> ingress=true --overwrite"
  if [ "$DRY_RUN" != "true" ]; then
    err "没有入口节点,中止。用 --label-nodes 指定或先手动打标签"
    exit 1
  fi
fi

ok "前置检查通过"

# ============================================================
# 3/5 apply deploy.yaml
# ============================================================
log "[3/5] apply deploy.yaml"

if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] 会 kubectl apply -f $DEPLOY_YAML"
  [ -n "$SERVICE_TYPE" ] && warn "[dry-run] 然后 patch Service.type=$SERVICE_TYPE"
else
  kubectl apply -f "$DEPLOY_YAML"
  # 覆盖 Service.type(如果用户指定)
  if [ -n "$SERVICE_TYPE" ]; then
    log "  覆盖 Service.type → $SERVICE_TYPE"
    kubectl -n ingress-nginx patch svc ingress-nginx-controller \
      --type=merge -p "{\"spec\":{\"type\":\"$SERVICE_TYPE\"}}"
  fi
fi
ok "deploy.yaml 已 apply"

# ============================================================
# 4/5 等所有组件 ready
# ============================================================
log "[4/5] 等待组件 ready"

if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] 跳过等待"
else
  # DaemonSet
  log "  等 ingress-nginx-controller DaemonSet..."
  kubectl -n ingress-nginx rollout status ds/ingress-nginx-controller --timeout=300s
  ok "ingress-nginx-controller ready"

  # Admission webhook Jobs(ttlSecondsAfterFinished=0 → 完成后自动删,所以可能已不存在)
  for job in ingress-nginx-admission-create ingress-nginx-admission-patch; do
    if kubectl -n ingress-nginx get job "$job" >/dev/null 2>&1; then
      log "  等 $job Job..."
      kubectl -n ingress-nginx wait --for=condition=Complete "job/$job" --timeout=120s 2>/dev/null || \
        warn "$job 未完成(查看: kubectl -n ingress-nginx describe job $job)"
    fi
  done
  ok "admission webhook 就绪"
fi

# ============================================================
# 5/5 验证
# ============================================================
log "[5/5] 验证"

if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] 跳过验证"
  exit 0
fi

kubectl -n ingress-nginx get pods -o wide

# 取一个 ingress 节点的 IP 测试 80 端口(hostNetwork 直绑)
INGRESS_NODE=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null)
if [ -n "$INGRESS_NODE" ]; then
  log "  测试节点 $INGRESS_NODE:80(hostNetwork 直绑)..."
  if curl -sI --max-time 5 "http://$INGRESS_NODE:80" 2>/dev/null | grep -q 'HTTP'; then
    ok "节点 $INGRESS_NODE:80 可达(ingress-nginx controller 在 listen)"
  else
    warn "节点 $INGRESS_NODE:80 不可达(防火墙 / 端口冲突 / 网络限制)"
  fi
fi

# Service 类型检查 + LB IP 状态
SVC_TYPE=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.type}')
log "  Service type = $SVC_TYPE"
if [ "$SVC_TYPE" = "LoadBalancer" ]; then
  LB_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [ -n "$LB_IP" ]; then
    ok "LB IP 已分配:$LB_IP"
    if curl -sI --max-time 5 "http://$LB_IP:80" 2>/dev/null | grep -q 'HTTP'; then
      ok "LB IP $LB_IP:80 可达 — BGP-LB + ECMP 链路验证通过 🎉"
    else
      warn "LB IP $LB_IP:80 不通,检查:"
      warn "  ① Calico BGP peer 状态:kubectl -n calico-system exec ds/calico-node -- birdcl show protocols"
      warn "  ② 路由器侧 ECMP:ip route show $LB_IP/32(期望多 nexthop)"
    fi
  else
    warn "Service 是 LoadBalancer 但 EXTERNAL-IP <pending>"
    warn "  → 没装 Calico BGP-LB / MetalLB:加 --service-type=NodePort 重跑"
    warn "  → 或装 BGP-LB:bash ../calico/bgp-lb/install.sh ..."
  fi
fi

log "==== 安装完成 ===="
echo
echo "验证 Ingress:"
echo "  kubectl -n ingress-nginx get pods -o wide"
echo "  kubectl -n ingress-nginx get svc ingress-nginx-controller   # 看 EXTERNAL-IP"
echo "  kubectl get ingressclass nginx"
echo "  bash $(dirname "$0")/test.sh   # 端到端测试"
echo
echo "卸载:"
echo "  bash $(dirname "$0")/uninstall.sh --apply"
