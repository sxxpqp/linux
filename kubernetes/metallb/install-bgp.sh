#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — MetalLB BGP 模式一键安装
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/metallb/install-bgp.sh
# 用法: bash install-bgp.sh --my-asn=64500 --peer-asn=64501 --peer-address=172.16.150.1
#
# 跟 L2 模式区别:
#   L2: speaker 选 leader 节点回 ARP → 所有流量集中到 1 个节点 → 节点间再转发
#   BGP: 3 个节点都跟路由器建 peer → ECMP 负载均衡 → 流量直达到目标节点
#
# 架构:
#   Internet → 路由器(ECMP) → node1/2/3:80 → ingress-nginx(hostNetwork)
#                                                     ↓
#                                               Service → Pod
#
# 路由器侧只需配 BGP neighbor(3 行就够,单播 peering,不跑 OSPF/IS-IS):
#   router bgp 64501
#     neighbor 172.16.150.128 remote-as 64500
#     neighbor 172.16.150.129 remote-as 64500
#     neighbor 172.16.150.130 remote-as 64500

set -euo pipefail

MY_ASN=""
PEER_ASN=""
PEER_ADDRESS=""
DRY_RUN="false"
VERSION="${VERSION:-v0.14.8}"
NS="metallb-system"

usage() {
  cat <<'EOF'
用法: bash install-bgp.sh --my-asn=<ASN> --peer-asn=<ASN> --peer-address=<IP> [选项]

必填:
  --my-asn=ASN           集群侧 AS 号(私有 AS 64512-65534)
  --peer-asn=ASN         上游路由器 AS 号
  --peer-address=IP      上游路由器 IP(单播 BGP 邻居地址)

可选:
  --dry-run              只打印配置不执行
  -h, --help             显示帮助

示例:
  bash install-bgp.sh \
    --my-asn=64500 \
    --peer-asn=64501 \
    --peer-address=172.16.150.1
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --my-asn=*)       MY_ASN="${1#*=}" ;;
    --peer-asn=*)     PEER_ASN="${1#*=}" ;;
    --peer-address=*) PEER_ADDRESS="${1#*=}" ;;
    --dry-run)        DRY_RUN="true" ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [ -z "$MY_ASN" ] || [ -z "$PEER_ASN" ] || [ -z "$PEER_ADDRESS" ]; then
  echo "ERROR: --my-asn / --peer-asn / --peer-address 都是必填" >&2
  usage >&2
  exit 1
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# 1/4 前置检查
# ============================================================
log "[1/4] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
ok "kubectl 可用"

if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  err "MetalLB 还没装,先跑: bash install.sh"
  exit 1
fi
ok "MetalLB namespace 存在"

# 确认节点 IP(用于打印路由器侧配置)
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
log "集群节点 IP: $NODE_IPS"
log "路由器需配的 BGP neighbor:"
for ip in $NODE_IPS; do
  echo "    neighbor $ip remote-as $MY_ASN"
done

# ============================================================
# 2/4 关 L2(并存没关系,但生产建议只留 BGP)
# ============================================================
log "[2/4] 关闭 L2 模式"

if kubectl -n "${NS}" get l2advertisement default-l2 >/dev/null 2>&1; then
  log "  删除 default-l2 L2Advertisement..."
  [ "$DRY_RUN" != "true" ] && kubectl -n "${NS}" delete l2advertisement default-l2 --ignore-not-found
  ok "L2 已关"
else
  ok "L2 不存在,跳过"
fi

# ============================================================
# 3/4 apply BGP 配置
# ============================================================
log "[3/4] apply BGP 配置"

log "  BGPPeer: 集群 AS=$MY_ASN ← → 路由器 AS=$PEER_ASN @ $PEER_ADDRESS"

if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] 会 apply bgp.yaml(替换 ASN / peerAddress)"
else
  kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: BGPPeer
metadata:
  name: gateway
  namespace: ${NS}
spec:
  myASN: ${MY_ASN}
  peerASN: ${PEER_ASN}
  peerAddress: ${PEER_ADDRESS}
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: default-bgp
  namespace: ${NS}
spec:
  ipAddressPools:
    - default-pool
EOF
fi
ok "BGP 配置已 apply"

# ============================================================
# 4/4 验证 BGP peer 状态
# ============================================================
log "[4/4] 验证 BGP peer"

if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] 跳过验证"
else
  # 等 speaker 重建 BGP session(几秒到十几秒)
  log "  等 BGP session 建立(最多 30s)..."
  ESTABLISHED=false
  for i in $(seq 1 6); do
    sleep 5
    # 查看 speaker 日志确认 BGP peer 状态
    if kubectl -n "${NS}" logs -l app=metallb,component=speaker --tail=30 2>/dev/null | grep -q "BGP peer.*established\|bgp_peer.*established\|peer.*$PEER_ADDRESS.*Established"; then
      ESTABLISHED=true
      break
    fi
    log "  ...等 BGP session($((i*5))s)"
  done

  if [ "$ESTABLISHED" = "true" ]; then
    ok "BGP peer $PEER_ADDRESS Established"
  else
    warn "BGP peer 未确认 Established,检查:"
    warn "  1. 路由器 BGP 是否已配 neighbor(上面打印的那几行)"
    warn "  2. kubectl -n ${NS} logs -l app=metallb,component=speaker | grep -i bgp"
    warn "  3. 路由器侧: show bgp summary / display bgp peer"
  fi
fi

echo
log "==== BGP 安装完成 ===="
echo
echo "路由器侧配置(黏贴即用):"
echo "  router bgp $PEER_ASN"
for ip in $NODE_IPS; do
  echo "    neighbor $ip remote-as $MY_ASN"
done
echo
echo "验证 ECMP(路由器侧):"
echo "  show ip route <LB_IP>     # 应该看到 3 条等价路由"
echo
echo "MetalLB 状态:"
echo "  kubectl -n ${NS} get bgppeer"
echo "  kubectl -n ${NS} logs -l app=metallb,component=speaker | grep -i bgp"
echo
echo "切回 L2:"
echo "  kubectl -n ${NS} delete bgppeer gateway"
echo "  kubectl -n ${NS} delete bgpadvertisement default-bgp"
echo "  kubectl apply -f pool.yaml   # pool.yaml 里有 L2Advertisement"
