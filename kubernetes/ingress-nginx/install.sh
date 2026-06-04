#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — ingress-nginx v1.15.1 DaemonSet + hostNetwork
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/ingress/install.sh
# 用法: curl -sL <URL> -o install.sh && bash install.sh [选项]
#
# 基于官方 cloud/deploy.yaml 改造:
#   Deployment → DaemonSet, 加 hostNetwork/ClusterFirstWithHostNet/nodeSelector
#   详见 deploy-guide.md

set -euo pipefail

INGRESS_VERSION="v1.15.1"
LABEL_NODES=""
DRY_RUN="false"

usage() {
  cat <<'EOF'
用法: bash install.sh [选项]

可选:
  --label-nodes=N1,N2       打 ingress=true 标签的节点(逗号分隔)
  --label-nodes=all          所有 linux worker 节点都打标签
  --dry-run                  只检查不打标签不 apply
  -h, --help                 显示帮助

示例:
  # 给 node1/node2 打标签并安装
  bash install.sh --label-nodes=node1,node2

  # 所有节点都跑 ingress(测试环境)
  bash install.sh --label-nodes=all

  # 节点已打好标签,直接装
  bash install.sh
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --label-nodes=*) LABEL_NODES="${1#*=}" ;;
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
else
  kubectl apply -f "$DEPLOY_YAML"
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

# 取一个 ingress 节点的 IP 测试 80 端口
INGRESS_NODE=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null)
if [ -n "$INGRESS_NODE" ]; then
  log "  测试节点 $INGRESS_NODE:80..."
  if curl -sI --max-time 5 "http://$INGRESS_NODE:80" 2>/dev/null | grep -q 'HTTP'; then
    ok "节点 $INGRESS_NODE:80 可达(ingress-nginx controller 在 listen)"
  else
    warn "节点 $INGRESS_NODE:80 不可达(可能是防火墙/端口冲突,也可能是网络限制)"
  fi
fi

log "==== 安装完成 ===="
echo
echo "验证 Ingress:"
echo "  kubectl -n ingress-nginx get pods -o wide"
echo "  kubectl get ingressclass nginx"
echo "  curl -H 'Host: demo.local' http://<ingress-node-ip>/"
echo
echo "卸载:"
echo "  bash $(dirname "$0")/uninstall.sh --apply"
