#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — Calico 切到 BGP 模式(从 eBPF + VXLAN 切过来)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/switch-to-bgp.sh
# 用法: bash switch-to-bgp.sh --my-asn=64500 --peer-asn=64501 --peer-address=172.16.150.1
#
# 跟 eBPF + VXLAN 模式区别:
#   eBPF+VXLAN: 跨节点 VXLAN 封包, 不暴露 Pod 路由给外部, kube-proxy 可替换
#   BGP:        节点跑 bird BGP, Pod CIDR 宣告到物理网络, 外部直连 Pod IP, 需要 kube-proxy
#
# ⚠ BGP 模式不支持 kube-proxy replacement(bpfKubeProxyIptablesCleanupEnabled),
#   切到 BGP 后需恢复 kube-proxy(脚本会自动做).
#
# 检测当前是 operator 还是 manifest 模式, 自动适配 API.

set -euo pipefail

MY_ASN=""
PEER_ASN=""
PEER_ADDRESS=""
DRY_RUN="false"

usage() {
  cat <<'EOF'
用法: bash switch-to-bgp.sh --my-asn=<ASN> --peer-asn=<ASN> --peer-address=<IP> [选项]

必填:
  --my-asn=ASN           集群侧 AS 号(私有 AS 64512-65534)
  --peer-asn=ASN         上游路由器 AS 号
  --peer-address=IP      上游路由器 IP

可选:
  --dry-run              只打印 diff 不执行
  -h, --help             显示帮助

示例:
  bash switch-to-bgp.sh \
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

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }

# 探测模式: operator(calico-system) 还是 manifest(kube-system)
CALICO_NS=""
CALICO_API=""
if kubectl get ns calico-system >/dev/null 2>&1; then
  CALICO_NS="calico-system"
  CALICO_API="operator"
elif kubectl -n kube-system get ds calico-node >/dev/null 2>&1; then
  CALICO_NS="kube-system"
  CALICO_API="manifest"
else
  err "未找到 Calico(namespace 既没有 calico-system 也没有 kube-system/calico-node)"
  exit 1
fi

log "Calico 模式: $CALICO_API (namespace=$CALICO_NS)"

# ============================================================
# 1/5 关 eBPF(切回 iptables dataplane)
# ============================================================
log "[1/5] 关 eBPF"

if [ "$CALICO_API" = "operator" ]; then
  CURRENT_DATAPLANE=$(kubectl get installation default -o jsonpath='{.spec.calicoNetwork.linuxDataplane}' 2>/dev/null || echo "Iptables")
  if [ "$CURRENT_DATAPLANE" = "BPF" ]; then
    log "  切 linuxDataplane: BPF → Iptables"
    if [ "$DRY_RUN" != "true" ]; then
      kubectl patch installation default --type=merge \
        -p '{"spec":{"calicoNetwork":{"linuxDataplane":"Iptables"}}}' 2>/dev/null || true
    fi
  else
    ok "dataplane 已是 $CURRENT_DATAPLANE,跳过"
  fi
else
  if kubectl get felixconfiguration default -o jsonpath='{.spec.bpfEnabled}' 2>/dev/null | grep -q true; then
    log "  关 FelixConfiguration.bpfEnabled"
    if [ "$DRY_RUN" != "true" ]; then
      kubectl patch felixconfiguration default --type=merge \
        -p '{"spec":{"bpfEnabled":false,"bpfKubeProxyIptablesCleanupEnabled":false}}' 2>/dev/null || true
    fi
  else
    ok "BPF 已关,跳过"
  fi
fi

# ============================================================
# 2/5 恢复 kube-proxy(BGP 模式需要它做 ClusterIP NAT)
# ============================================================
log "[2/5] 恢复 kube-proxy"

if kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
  ok "kube-proxy 已存在,跳过"
else
  log "  重建 kube-proxy(从 kubeadm-config 生成)..."
  if [ "$DRY_RUN" != "true" ]; then
    # 先重建 ConfigMap(kube-proxy ConfigMap 可能在删 kube-proxy 时被一起删了)
    if ! kubectl -n kube-system get cm kube-proxy >/dev/null 2>&1; then
      # 从 kubeadm-config 提取 proxy 配置,重建 ConfigMap
      kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null > /tmp/kubeadm-conf.yaml || true
      if [ -s /tmp/kubeadm-conf.yaml ]; then
        kubeadm init phase addon kube-proxy --config /tmp/kubeadm-conf.yaml 2>/dev/null || \
        kubeadm init phase addon kube-proxy 2>/dev/null || true
        rm -f /tmp/kubeadm-conf.yaml
      else
        kubeadm init phase addon kube-proxy 2>/dev/null || true
      fi
    else
      kubeadm init phase addon kube-proxy 2>/dev/null || true
    fi
    kubectl -n kube-system rollout status ds/kube-proxy --timeout=120s 2>/dev/null || true
  fi
  if kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
    ok "kube-proxy 已恢复"
  else
    warn "kube-proxy 恢复失败(BGP 模式需要它做 ClusterIP NAT),手动装:"
    warn "  kubeadm init phase addon kube-proxy"
  fi
fi

# ============================================================
# 3/5 等 calico-node 重启(上面改了 dataplane)
# ============================================================
log "[3/5] 等 calico-node 重启"

if [ "$DRY_RUN" != "true" ]; then
  kubectl -n "$CALICO_NS" rollout status ds/calico-node --timeout=300s
fi
ok "calico-node ready"

# ============================================================
# 4/5 开 BGP + 改 IPPool(关 VXLAN 封包)
# ============================================================
log "[4/5] 开 BGP"

# 4a. 改 IPPool: 关 VXLAN, 开 BGP 宣告
IPPOOL=$(kubectl get ippools -o name 2>/dev/null | head -1)
if [ -n "$IPPOOL" ]; then
  log "  IPPool $IPPOOL: nodeSelector=all(), encapsulation=None"
  if [ "$DRY_RUN" != "true" ]; then
    kubectl patch "$IPPOOL" --type=merge -p \
      '{"spec":{"ipipMode":"Never","vxlanMode":"Never","natOutgoing":true,"nodeSelector":"all()"}}' 2>/dev/null || true
  fi
  ok "IPPool 已改"
else
  warn "未找到 IPPool,跳过"
fi

# 4b. Operator 模式: 改 Installation CR(先等 operator 收敛)
if [ "$CALICO_API" = "operator" ]; then
  log "  Installation CR: bgp=Enabled, encapsulation=None"
  if [ "$DRY_RUN" != "true" ]; then
    # 等 operator 收敛完 dataplane 切换再开 BGP,避免 patch 被 operator 覆盖
    sleep 10
    kubectl patch installation default --type=merge -p '{
      "spec":{
        "calicoNetwork":{
          "bgp":"Enabled",
          "ipPools":[{
            "name":"default-ipv4-ippool",
            "encapsulation":"None",
            "natOutgoing":true,
            "nodeSelector":"all()"
          }]
        }
      }
    }' 2>/dev/null || true
  fi
fi

# 4c. 创建 BGPPeer
log "  BGPPeer: 集群 AS=$MY_ASN ← → 路由器 AS=$PEER_ASN @ $PEER_ADDRESS"
if [ "$DRY_RUN" != "true" ]; then
  kubectl apply -f - <<EOF
apiVersion: crd.projectcalico.org/v1
kind: BGPPeer
metadata:
  name: upstream-router
spec:
  peerIP: ${PEER_ADDRESS}
  asNumber: ${PEER_ASN}
EOF
fi
ok "BGPPeer 已创建"

# 4d. BGPConfiguration(设置集群 AS)
if [ "$DRY_RUN" != "true" ]; then
  if kubectl get bgpconfiguration default >/dev/null 2>&1; then
    kubectl patch bgpconfiguration default --type=merge \
      -p "{\"spec\":{\"asNumber\":${MY_ASN},\"nodeToNodeMeshEnabled\":true}}" 2>/dev/null || true
  else
    kubectl apply -f - <<EOF
apiVersion: crd.projectcalico.org/v1
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: ${MY_ASN}
  nodeToNodeMeshEnabled: true
EOF
  fi
fi
ok "BGPConfiguration(AS=$MY_ASN) 已设置"

# ============================================================
# 5/5 重启 calico-node 加载 BGP + 验证
# ============================================================
log "[5/5] 重启 calico-node 加载 BGP"

if [ "$DRY_RUN" != "true" ]; then
  kubectl -n "$CALICO_NS" rollout restart ds/calico-node 2>/dev/null || true
  kubectl -n "$CALICO_NS" rollout status ds/calico-node --timeout=300s
fi
ok "calico-node 已重启"

# 验证 BGP peer
log "  验证 BGP peer(等 15s)..."
sleep 15
if [ "$DRY_RUN" != "true" ]; then
  NODE_POD=$(kubectl -n "$CALICO_NS" get pod -l k8s-app=calico-node -o name 2>/dev/null | head -1)
  if [ -n "$NODE_POD" ]; then
    BGP_STATUS=$(kubectl -n "$CALICO_NS" exec "$NODE_POD" -- birdcl show protocols 2>/dev/null | grep -A2 "peer\|$PEER_ADDRESS" || true)
    if echo "$BGP_STATUS" | grep -q "Established\|Up"; then
      ok "BGP peer $PEER_ADDRESS Established"
    else
      warn "BGP peer 状态待确认,检查:"
      warn "  kubectl -n $CALICO_NS exec $NODE_POD -- birdcl show protocols"
    fi
  fi
fi

echo
log "==== BGP 切换完成 ===="
echo
echo "路由器侧配置:"
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
echo "  router bgp $PEER_ASN"
for ip in $NODE_IPS; do
  echo "    neighbor $ip remote-as $MY_ASN"
done
echo
echo "验证:"
echo "  kubectl -n $CALICO_NS exec ds/calico-node -- birdcl show protocols"
echo "  kubectl get bgppeer,bgpconfiguration"
echo
