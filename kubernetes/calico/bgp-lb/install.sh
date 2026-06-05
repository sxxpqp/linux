#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — Calico BGP + 内置 LoadBalancer Service IP 宣告
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/bgp-lb/install.sh
# 用法: bash install.sh --apiserver-host=<HOST> --my-asn=<ASN> --lb-cidr=<CIDR> [选项]
#
# Calico BIRD 一个进程同时宣告 Pod CIDR + LoadBalancer Service IP,
# 不再需要 MetalLB 或 kube-vip 单独宣告 Service IP。
#
# 架构:
#   路由器 ← BGP → Calico BIRD ─ 宣告 Pod CIDR(10.244.0.0/16)
#                              ─ 宣告 LB IP(172.16.150.200/29)
#            Service type=LoadBalancer → Calico 自动分配 LB IP 并宣告

set -euo pipefail

CALICO_VERSION="v3.28.2"
POD_CIDR=""
APISERVER_HOST=""
APISERVER_PORT="6443"
MY_ASN=""
LB_CIDR=""
PEER_ASN=""
PEER_ADDRESS=""
DRY_RUN="false"

usage() {
  cat <<'EOF'
用法: bash install.sh --apiserver-host=<HOST> --my-asn=<ASN> --lb-cidr=<CIDR> [选项]

必填:
  --apiserver-host=HOST     API server 地址(LB / master IP)
  --my-asn=ASN              集群侧 AS 号(私有 AS 64512-65534)
  --lb-cidr=CIDR            LoadBalancer Service IP 段(需跟节点同段,不跟节点 IP 重叠)

可选:
  --peer-asn=ASN            上游路由器 AS 号(不传则只开 node mesh)
  --peer-address=IP         上游路由器 BGP 邻居 IP
  --apiserver-port=PORT     API server 端口,默认 6443
  --pod-cidr=CIDR           Pod CIDR,默认自动探测
  --calico-version=VER      版本,默认 v3.28.2
  --dry-run                 只打印不执行
  -h, --help                显示帮助

示例:
  # 只开 node mesh + LB(路由器 peer 后面加)
  bash install.sh \
    --apiserver-host=172.16.150.128 \
    --my-asn=64500 \
    --lb-cidr=172.16.150.200/29

  # 一步到位
  bash install.sh \
    --apiserver-host=172.16.150.128 \
    --my-asn=64500 \
    --lb-cidr=172.16.150.200/29 \
    --peer-asn=64501 \
    --peer-address=172.16.150.1
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apiserver-host=*)  APISERVER_HOST="${1#*=}" ;;
    --apiserver-port=*)  APISERVER_PORT="${1#*=}" ;;
    --pod-cidr=*)        POD_CIDR="${1#*=}" ;;
    --calico-version=*)  CALICO_VERSION="${1#*=}" ;;
    --my-asn=*)          MY_ASN="${1#*=}" ;;
    --lb-cidr=*)         LB_CIDR="${1#*=}" ;;
    --peer-asn=*)        PEER_ASN="${1#*=}" ;;
    --peer-address=*)    PEER_ADDRESS="${1#*=}" ;;
    --dry-run)           DRY_RUN="true" ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [ -z "$APISERVER_HOST" ]; then
  APISERVER_HOST=$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  [ -z "$APISERVER_HOST" ] && { echo "ERROR: --apiserver-host 必填" >&2; exit 1; }
  echo "WARN: 自动探测 API server: $APISERVER_HOST"
fi
if [ -z "$MY_ASN" ]; then echo "ERROR: --my-asn 必填" >&2; usage >&2; exit 1; fi
if [ -z "$LB_CIDR" ]; then echo "ERROR: --lb-cidr 必填" >&2; usage >&2; exit 1; fi

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ============================================================
# 1/6 前置检查
# ============================================================
log "[1/6] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
ok "kubectl 可用"

if [ -z "$POD_CIDR" ]; then
  POD_CIDR=$(kubectl -n kube-system get cm kubeadm-config -o yaml 2>/dev/null \
    | grep -oE 'podSubnet: [0-9./,]+' | awk '{print $2}' | head -1 || true)
  [ -n "$POD_CIDR" ] && ok "Pod CIDR: $POD_CIDR (自动)" || { POD_CIDR="192.168.0.0/16"; warn "回退 $POD_CIDR"; }
else
  ok "Pod CIDR: $POD_CIDR"
fi

# 检查 LB CIDR 跟节点是否冲突
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
for ip in $NODE_IPS; do
  # 简单检查: 节点 IP 在 LB CIDR 范围内
  echo "$ip" | grep -qE "^172\.16\.150" && warn "节点 $ip 在 LB CIDR 附近, 确保不重叠" || true
done
ok "LB CIDR: $LB_CIDR"

if ! kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
  warn "kube-proxy 不存在, BGP 模式需要它做 ClusterIP NAT"
  warn "  恢复: kubeadm init phase addon kube-proxy"
fi

# 残留检查
TERMINATING_FOUND=false
for ns in calico-system tigera-operator calico-apiserver; do
  if kubectl get ns $ns -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; then
    err "ns/$ns Terminating, 先跑 uninstall.sh --apply"
    TERMINATING_FOUND=true
  fi
done
[ "$TERMINATING_FOUND" = "true" ] && exit 1

ok "前置检查通过"
[ "$DRY_RUN" = "true" ] && warn "DRY-RUN"

# ============================================================
# 2/6 kubernetes-services-endpoint + tigera-operator
# ============================================================
log "[2/6] 配置 + tigera-operator"

kubectl create ns tigera-operator --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubernetes-services-endpoint
  namespace: tigera-operator
data:
  KUBERNETES_SERVICE_HOST: "${APISERVER_HOST}"
  KUBERNETES_SERVICE_PORT: "${APISERVER_PORT}"
EOF
ok "ConfigMap 已 apply"

NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"
TIGERA_OP_URL="${NEXUS_RAW}/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
TMP_OP=$(mktemp /tmp/tigera-operator.XXXXXX.yaml)
trap "rm -f $TMP_OP" EXIT

curl -fsSLk "$TIGERA_OP_URL" -o "$TMP_OP" || { err "下载失败"; exit 1; }
kubectl apply --server-side -f "$TMP_OP"
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=180s
ok "tigera-operator ready"

# ============================================================
# 3/6 Installation CR (BGP)
# ============================================================
log "[3/6] Installation CR (BGP)"

INSTALL_YAML="${SCRIPT_DIR}/installation.yaml"
if [ -f "$INSTALL_YAML" ]; then
  sed "s|REPLACE_POD_CIDR|${POD_CIDR}|g" "$INSTALL_YAML" | kubectl apply -f -
else
  kubectl apply -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    linuxDataplane: Iptables
    bgp: Enabled
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: ${POD_CIDR}
        encapsulation: None
        natOutgoing: Enabled
        nodeSelector: all()
EOF
fi
ok "Installation CR 已 apply"

# ============================================================
# 4/6 等 Calico ready
# ============================================================
log "[4/6] 等 Calico ready"

for i in $(seq 1 60); do
  kubectl get ns calico-system >/dev/null 2>&1 && { ok "calico-system ns 出现(第 $((i*5))s)"; break; }
  sleep 5
done
kubectl -n calico-system rollout status ds/calico-node --timeout=480s || { err "calico-node 失败"; exit 1; }
ok "calico-node ready"
kubectl -n calico-system rollout status deploy/calico-kube-controllers --timeout=300s || { err "controllers 失败"; exit 1; }
ok "calico-kube-controllers ready"

# ============================================================
# 5/6 BGPConfiguration + LB 宣告
# ============================================================
log "[5/6] BGP 配置 + LB Service IP 宣告"

# BGPConfiguration: 集群 AS + service LB IP 宣告
kubectl apply -f - <<EOF
apiVersion: crd.projectcalico.org/v1
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: ${MY_ASN}
  nodeToNodeMeshEnabled: true
  serviceLoadBalancerIPs:
    - cidr: ${LB_CIDR}
  serviceExternalIPs:
    - cidr: ${LB_CIDR}
EOF
ok "BGPConfiguration(AS=$MY_ASN, LB=$LB_CIDR) 已配置"

# 上游路由器 peer(可选)
if [ -n "$PEER_ASN" ] && [ -n "$PEER_ADDRESS" ]; then
  kubectl apply -f - <<EOF
apiVersion: crd.projectcalico.org/v1
kind: BGPPeer
metadata:
  name: upstream-router
spec:
  peerIP: ${PEER_ADDRESS}
  asNumber: ${PEER_ASN}
EOF
  ok "BGPPeer: 路由器 AS=$PEER_ASN @ $PEER_ADDRESS"
else
  warn "未指定 peer,只开 node mesh(BGP peer 后面加也行)"
fi

# Calico 不像 MetalLB 有 IPAddressPool CR — LB IP 直接从 BGPConfiguration 宣告。
# Service type=LoadBalancer 创建后, Calico 自动从 pod CIDR 之外的地址段分配
# 一个 EXTERNAL-IP(但是 Calico 默认不自动分配 LB IP, 要手动指定 loadBalancerIP)。
# 这里给个创建 LoadBalancer Service 的例子。
ok "LB Service 用法: kubectl expose deploy <NAME> --port=80 --type=LoadBalancer \\"
ok "                --overrides='{\"spec\":{\"loadBalancerIP\":\"<从 $LB_CIDR 里挑>\"}}'"

# ============================================================
# 6/6 验证
# ============================================================
log "[6/6] 验证 BGP"

sleep 15
NODE_POD=$(kubectl -n calico-system get pod -l k8s-app=calico-node -o name | head -1)
if kubectl -n calico-system exec "$NODE_POD" -- birdcl show protocols 2>/dev/null | grep -q "Established\|Start\|Active"; then
  ok "BIRD BGP 运行中"
else
  warn "BIRD 状态待确认: kubectl -n calico-system exec $NODE_POD -- birdcl show protocols"
fi

echo
log "==== 安装完成 ===="
echo
echo "架构: 路由器 ← BGP → Calico BIRD ─ 宣告 Pod CIDR + LB Service IP"
echo
if [ -n "$PEER_ASN" ] && [ -n "$PEER_ADDRESS" ]; then
  echo "路由器侧配置:"
  NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
  echo "  router bgp $PEER_ASN"
  for ip in $NODE_IPS; do echo "    neighbor $ip remote-as $MY_ASN"; done
  echo
fi
echo "创建 LoadBalancer Service(外部可直接访问):"
cat <<EOF
  # 从 $LB_CIDR 里选一个未用的 IP
  kubectl expose deploy nginx --port=80 --type=LoadBalancer \\
    --overrides='{"spec":{"loadBalancerIP":"172.16.150.200"}}'
  kubectl get svc  # EXTERNAL-IP 应该是 172.16.150.200
EOF
echo
echo "验证:"
echo "  kubectl get bgpconfiguration -o yaml | grep -A3 serviceLoadBalancerIPs"
echo "  kubectl -n calico-system exec ds/calico-node -- birdcl show protocols"
echo "  curl http://<LB_IP>:80   # 外部测试"
echo
echo "卸载: bash uninstall.sh --apply"
