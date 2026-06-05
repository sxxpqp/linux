#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — Calico BGP 模式安装
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/bgp/install.sh
# 用法: bash install.sh --apiserver-host=<HOST> --my-asn=<ASN> --peer-asn=<ASN> --peer-address=<IP> [选项]
#
# 跟 operator 默认 BPF 模式区别:
#   BPF: linuxDataplane=BPF, VXLAN 封包, 替换 kube-proxy
#   BGP: linuxDataplane=Iptables, BIRD BGP 路由, kube-proxy 保留
#
# 默认只开 node mesh, 上游路由器 peer 可选。

set -euo pipefail

CALICO_VERSION="v3.28.2"
POD_CIDR=""
APISERVER_HOST=""
APISERVER_PORT="6443"
MY_ASN=""
PEER_ASN=""
PEER_ADDRESS=""
DRY_RUN="false"

usage() {
  cat <<'EOF'
用法: bash install.sh --apiserver-host=<HOST> --my-asn=<ASN> [选项]

必填:
  --apiserver-host=HOST     API server 地址(LB / master IP)
  --my-asn=ASN              集群侧 AS 号(私有 AS 64512-65534)

可选:
  --peer-asn=ASN            上游路由器 AS 号(不传则只开 node mesh)
  --peer-address=IP         上游路由器 BGP 邻居 IP(不传则只开 node mesh)
  --apiserver-port=PORT     API server 端口,默认 6443
  --pod-cidr=CIDR           Pod CIDR,默认自动探测
  --calico-version=VER      版本,默认 v3.28.2
  --dry-run                 只打印不执行
  -h, --help                显示帮助

示例:
  # 只开 node mesh(等路由器就绪后再加 peer)
  bash install.sh --apiserver-host=172.16.150.128 --my-asn=64500

  # 一步到位(路由器已配好)
  bash install.sh --apiserver-host=172.16.150.128 --my-asn=64500 \
    --peer-asn=64501 --peer-address=172.16.150.1
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apiserver-host=*)  APISERVER_HOST="${1#*=}" ;;
    --apiserver-port=*)  APISERVER_PORT="${1#*=}" ;;
    --pod-cidr=*)        POD_CIDR="${1#*=}" ;;
    --calico-version=*)  CALICO_VERSION="${1#*=}" ;;
    --my-asn=*)          MY_ASN="${1#*=}" ;;
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

if [ -z "$MY_ASN" ]; then
  echo "ERROR: --my-asn 必填" >&2
  usage >&2
  exit 1
fi
# peer 参数可选: 不传就只开 node mesh, 路由器 peer 后面再加

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

# Pod CIDR
if [ -z "$POD_CIDR" ]; then
  POD_CIDR=$(kubectl -n kube-system get cm kubeadm-config -o yaml 2>/dev/null \
    | grep -oE 'podSubnet: [0-9./,]+' | awk '{print $2}' | head -1 || true)
  if [ -n "$POD_CIDR" ]; then
    ok "Pod CIDR: $POD_CIDR (自动探测)"
  else
    POD_CIDR="192.168.0.0/16"
    warn "未探测到,回退 $POD_CIDR"
  fi
else
  ok "Pod CIDR: $POD_CIDR (用户指定)"
fi

# kube-proxy 必须在(ClusterIP NAT 靠它)
if ! kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
  warn "kube-proxy 不存在,BGP 模式需要它做 ClusterIP NAT"
  warn "  恢复: kubeadm init phase addon kube-proxy"
fi

# 冲突 CNI
if kubectl get ds -n kube-system 2>/dev/null | grep -qE 'cilium|kube-flannel|weave'; then
  err "检测到其他 CNI,请先卸载"
  exit 1
fi

# 残留检查(同 operator install.sh)
TERMINATING_FOUND=false
for cr in installation apiserver; do
  if kubectl get $cr default -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
    err "$cr/default Terminating,无法安装"
    TERMINATING_FOUND=true
  fi
done
for ns in calico-system tigera-operator calico-apiserver; do
  if kubectl get ns $ns -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; then
    err "ns/$ns Terminating,先跑 uninstall.sh --apply"
    TERMINATING_FOUND=true
  fi
done
[ "$TERMINATING_FOUND" = "true" ] && exit 1

ok "前置检查通过"

[ "$DRY_RUN" = "true" ] && warn "DRY-RUN 模式"

# ============================================================
# 2/6 kubernetes-services-endpoint ConfigMap
# ============================================================
log "[2/6] 配置 kubernetes-services-endpoint ConfigMap"

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

# ============================================================
# 3/6 tigera-operator
# ============================================================
log "[3/6] 安装 tigera-operator ($CALICO_VERSION)"

NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"
TIGERA_OP_URL="${NEXUS_RAW}/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
TMP_OP=$(mktemp /tmp/tigera-operator.XXXXXX.yaml)
trap "rm -f $TMP_OP" EXIT

curl -fsSLk "$TIGERA_OP_URL" -o "$TMP_OP" || { err "下载失败"; exit 1; }
kubectl apply --server-side -f "$TMP_OP"
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=180s
ok "tigera-operator ready"

# ============================================================
# 4/6 Installation CR (BGP 配置)
# ============================================================
log "[4/6] apply Installation CR (BGP)"

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
# 5/6 等 Calico ready
# ============================================================
log "[5/6] 等待 Calico ready"

for i in $(seq 1 60); do
  if kubectl get ns calico-system >/dev/null 2>&1; then
    ok "calico-system ns 已出现(第 $((i*5))s)"
    break
  fi
  sleep 5
done

kubectl -n calico-system rollout status ds/calico-node --timeout=480s || { err "calico-node 失败"; exit 1; }
ok "calico-node ready"
kubectl -n calico-system rollout status deploy/calico-kube-controllers --timeout=300s || { err "calico-kube-controllers 失败"; exit 1; }
ok "calico-kube-controllers ready"

# ============================================================
# 6/6 BGP peer + 验证
# ============================================================
log "[6/6] 配置 BGP peer"

# BGPConfiguration(集群 AS)
kubectl apply -f - <<EOF
apiVersion: crd.projectcalico.org/v1
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: ${MY_ASN}
  nodeToNodeMeshEnabled: true
EOF

# BGPPeer(上游路由器,可选)
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
  ok "BGP peer 已配置(上游路由器 AS=$PEER_ASN @ $PEER_ADDRESS)"
else
  warn "未指定 --peer-asn/--peer-address,跳过上游 peer(只有 node mesh)"
  warn "  后续加 peer: kubectl apply -f - <<< 'apiVersion: crd.projectcalico.org/v1 ...'"
fi

# 等 BIRD 建 BGP session
log "  等 BGP session 收敛..."
sleep 15
NODE_POD=$(kubectl -n calico-system get pod -l k8s-app=calico-node -o name | head -1)
if kubectl -n calico-system exec "$NODE_POD" -- birdcl show protocols 2>/dev/null | grep -q "Established\|Up\|Start\|Active"; then
  ok "BIRD BGP 进程运行中"
else
  warn "BIRD 状态待确认"
  warn "  kubectl -n calico-system exec $NODE_POD -- birdcl show protocols"
fi

echo
log "==== BGP 安装完成 ===="
echo
if [ -n "$PEER_ASN" ] && [ -n "$PEER_ADDRESS" ]; then
  echo "路由器侧配置:"
  NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
  echo "  router bgp $PEER_ASN"
  for ip in $NODE_IPS; do
    echo "    neighbor $ip remote-as $MY_ASN"
  done
  echo
else
  echo "后续加路由器 peer:"
  echo "  kubectl apply -f - <<EOF"
  echo "  apiVersion: crd.projectcalico.org/v1"
  echo "  kind: BGPPeer"
  echo "  metadata:"
  echo "    name: upstream-router"
  echo "  spec:"
  echo "    peerIP: <ROUTER_IP>"
  echo "    asNumber: <ROUTER_ASN>"
  echo "  EOF"
  echo
fi
echo "验证:"
echo "  kubectl -n calico-system exec ds/calico-node -- birdcl show protocols"
echo "  kubectl get bgppeer,bgpconfiguration,ippools"
echo
echo "卸载: bash uninstall.sh --apply"
