#!/usr/bin/env bash
# 系统: Kubernetes (K8s)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/onpremises/manifest/uninstall.sh
# 用法: curl -sL <URL> -o uninstall.sh && bash uninstall.sh [选项]
#
# 卸载 manifest 方式装的 Calico(单 calico.yaml,跑在 kube-system)。
# 默认 dry-run,加 --apply 才真删。
#
# 卸载顺序(顺序错了 kube-proxy 起不来):
#   1. 切回 iptables dataplane(Calico BPF 会清理 kube-proxy 的 iptables 规则,必须先切)
#   2. 恢复 kube-proxy(如果之前删了)
#   3. 反向 delete calico.yaml
#   4. 节点残留清理提示
#
# 卸载完后集群没有 CNI,要么立即装别的,要么重新装 Calico

set -euo pipefail

# ============================================================
# 默认值 / 参数解析
# ============================================================
CALICO_VERSION="v3.28.2"
APPLY="false"
RESTORE_KUBE_PROXY="auto"
SKIP_KUBE_PROXY_RESTORE="false"
APISERVER_HOST=""
FORCE="false"

usage() {
  cat <<'EOF'
用法: bash uninstall.sh [选项]

默认 dry-run。加 --apply 才真删。

选项:
  --apply                     真执行
  --restore-kube-proxy        强制恢复 kube-proxy
  --skip-kube-proxy-restore   跳过恢复(要立即装别的 CNI 时用)
  --apiserver-host=HOST       恢复 kube-proxy 时用,默认从 kubeadm-config 探测
  --calico-version=VER        Calico 版本(必须跟装时一致),默认 v3.28.2
  --force                     残留资源剥 finalizer
  -h, --help                  显示帮助

典型用法:
  bash uninstall.sh                  # 看计划
  bash uninstall.sh --apply          # 真删,自动恢复 kube-proxy
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="true" ;;
    --restore-kube-proxy) RESTORE_KUBE_PROXY="true" ;;
    --skip-kube-proxy-restore) SKIP_KUBE_PROXY_RESTORE="true" ;;
    --apiserver-host=*) APISERVER_HOST="${1#*=}" ;;
    --calico-version=*) CALICO_VERSION="${1#*=}" ;;
    --force) FORCE="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

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

# ============================================================
# 1/5 现状盘点
# ============================================================
log "[1/5] 前置检查 + 现状盘点"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }

HAS_CALICO_NODE=false
HAS_KUBE_PROXY=false
HAS_FELIX_BPF=false

kubectl -n kube-system get ds calico-node >/dev/null 2>&1 && HAS_CALICO_NODE=true
kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1 && HAS_KUBE_PROXY=true
[ "$(kubectl get felixconfiguration default -o jsonpath='{.spec.bpfEnabled}' 2>/dev/null)" = "true" ] && HAS_FELIX_BPF=true

echo
echo "  当前状态:"
echo "    calico-node DS (kube-system) : $HAS_CALICO_NODE"
echo "    kube-proxy DS                : $HAS_KUBE_PROXY"
echo "    Felix bpfEnabled             : $HAS_FELIX_BPF"
echo

if [ "$HAS_CALICO_NODE" = "false" ]; then
  ok "kube-system 没有 calico-node DS,看起来不是 manifest 方式装的"
  warn "如果是 operator 方式装的,请用 operator/uninstall.sh"
  exit 0
fi

if [ "$APPLY" != "true" ]; then
  warn "DRY-RUN 模式,只打印不执行"
fi

# 决策恢复 kube-proxy
RESTORE_DECISION="no"
if [ "$SKIP_KUBE_PROXY_RESTORE" = "true" ]; then
  warn "--skip-kube-proxy-restore:卸载后 Service 立即全断"
elif [ "$HAS_KUBE_PROXY" = "true" ]; then
  ok "kube-proxy 仍在,无需恢复"
else
  RESTORE_DECISION="yes"
fi

# ============================================================
# 2/5 切回 iptables dataplane(关键!不切的话恢复 kube-proxy 会失败)
# Calico BPF 模式会主动清理 kube-proxy iptables 规则,必须先关 BPF
# ============================================================
log "[2/5] 切回 iptables dataplane"

if [ "$HAS_FELIX_BPF" = "true" ]; then
  run "kubectl patch felixconfiguration default --type=merge -p '{\"spec\":{\"bpfEnabled\": false}}'"
  if [ "$APPLY" = "true" ]; then
    log "  重启 calico-node 让 BPF 程序 detach"
    kubectl -n kube-system rollout restart ds/calico-node
    kubectl -n kube-system rollout status ds/calico-node --timeout=300s
    ok "已切回 iptables 模式,BPF 程序已卸载"
  fi
else
  ok "FelixConfiguration.bpfEnabled 已是 false,跳过"
fi

# 删 kubernetes-services-endpoint ConfigMap(manifest 模式装在 kube-system)
run "kubectl -n kube-system delete cm kubernetes-services-endpoint --ignore-not-found"

# ============================================================
# 3/5 恢复 kube-proxy
# ============================================================
log "[3/5] 恢复 kube-proxy"

if [ "$RESTORE_DECISION" = "yes" ]; then
  if [ -z "$APISERVER_HOST" ]; then
    APISERVER_HOST=$(kubectl -n kube-system get cm kubeadm-config -o yaml 2>/dev/null \
      | grep -oE 'controlPlaneEndpoint: [^[:space:]]+' | head -1 | awk '{print $2}' | cut -d: -f1 || true)
    [ -z "$APISERVER_HOST" ] && APISERVER_HOST=$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  fi
  [ -z "$APISERVER_HOST" ] && { err "无法探测 API server,请 --apiserver-host=<HOST>"; exit 1; }

  if ! command -v kubeadm >/dev/null 2>&1; then
    err "本机没有 kubeadm,无法自动恢复 kube-proxy"
    warn "在 master 节点跑:"
    echo "    kubeadm init phase addon kube-proxy --apiserver-advertise-address=$APISERVER_HOST"
    exit 1
  fi

  POD_CIDR=$(kubectl -n kube-system get cm kubeadm-config -o yaml 2>/dev/null \
    | grep -oE 'podSubnet: [0-9./,]+' | awk '{print $2}' | head -1)

  run "kubeadm init phase addon kube-proxy --apiserver-advertise-address=$APISERVER_HOST --pod-network-cidr=$POD_CIDR"

  if [ "$APPLY" = "true" ]; then
    kubectl -n kube-system rollout status ds/kube-proxy --timeout=180s
    ok "kube-proxy 已恢复"
  fi
else
  log "  跳过"
fi

# ============================================================
# 4/5 反向 delete calico.yaml
# ============================================================
log "[4/5] 反向 delete calico.yaml"

NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"
CALICO_URL="${NEXUS_RAW}/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
TMP_YAML=$(mktemp /tmp/calico.XXXXXX.yaml)
trap "rm -f $TMP_YAML" EXIT

log "  拉取 $CALICO_URL"
if [ "$APPLY" = "true" ]; then
  if ! curl -fsSLk "$CALICO_URL" -o "$TMP_YAML"; then
    err "下载失败,手动删除:"
    echo "    kubectl -n kube-system delete ds calico-node"
    echo "    kubectl -n kube-system delete deploy calico-kube-controllers"
    echo "    kubectl delete crd \$(kubectl get crd -o name | grep -E 'projectcalico|tigera')"
    echo "    kubectl delete clusterrole,clusterrolebinding -l app=calico 2>/dev/null || true"
  else
    run "kubectl delete -f $TMP_YAML --ignore-not-found --timeout=180s"
  fi
else
  warn "[dry-run] 会下载 $CALICO_URL 后反向 delete"
fi

# Force 模式:残留 CRD 资源剥 finalizer
if [ "$FORCE" = "true" ] && [ "$APPLY" = "true" ]; then
  for cr in ippool felixconfiguration bgpconfiguration; do
    kubectl get ${cr}.crd.projectcalico.org -o name 2>/dev/null | while read r; do
      kubectl patch "$r" --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
  done
fi

# ============================================================
# 5/5 节点残留清理提示
# ============================================================
log "[5/5] 节点残留清理(每个 node 手动执行)"

NODES=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

cat <<EOF

每个节点需要清理:

  # 1. iptables KUBE-/CALI- 链
  iptables-save | grep -vE '^(:|-A )(KUBE|CALI|cali|kube)' | iptables-restore

  # 2. ipvs
  ipvsadm -C 2>/dev/null

  # 3. CNI 配置 + 二进制
  rm -f /etc/cni/net.d/*calico* /opt/cni/bin/calico /opt/cni/bin/calico-ipam

  # 4. Calico 数据目录
  rm -rf /var/lib/calico /var/log/calico /var/run/calico

  # 5. BPF 程序(如果开过 eBPF)
  bpftool prog list | grep -B1 calico && echo "有残留,建议重启节点"

节点列表:
EOF

if [ -n "$NODES" ]; then
  for ip in $NODES; do echo "  - $ip"; done
fi

cat <<EOF

【强烈建议】卸载完成后重启所有节点一次,清除内核 conntrack / BPF 残留。

EOF

if [ "$APPLY" != "true" ]; then
  warn "以上是 DRY-RUN,确认后跑: bash $0 --apply"
fi

log "==== 完成 ===="
