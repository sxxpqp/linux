#!/usr/bin/env bash
# 系统: Kubernetes (K8s)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/onpremises/operator/uninstall.sh
# 用法: curl -sL <URL> -o uninstall.sh && bash uninstall.sh [选项]
#
# 卸载 Tigera Operator 部署的 Calico,默认 dry-run(只打印计划),加 --apply 才真删。
#
# ⚠ 危险!卸载顺序:
#   1. 恢复 kube-proxy(如果之前删了),否则下一步删 Calico 时集群 Service 立即全断
#   2. 删 Installation CR + APIServer CR(operator 自动清理 calico-system)
#   3. 等 calico-system 资源全消失
#   4. 反向 delete tigera-operator.yaml
#   5. 删 tigera-operator namespace
#   6. 节点残留清理提示(iptables / cni / bpf 程序)
#
# 卸载完后集群没有 CNI,新建 Pod 拿不到 IP,要么立即装别的 CNI,要么重新跑 install.sh

set -euo pipefail

# ============================================================
# 默认值 / 参数解析
# ============================================================
CALICO_VERSION="v3.28.2"
APPLY="false"                  # 默认 dry-run,加 --apply 才真删
RESTORE_KUBE_PROXY="auto"      # auto(默认探测) / true / false
SKIP_KUBE_PROXY_RESTORE="false"
FORCE="false"                  # 剥 finalizer
KEEP_TIGERA_NS="false"
APISERVER_HOST=""

usage() {
  cat <<'EOF'
用法: bash uninstall.sh [选项]

默认行为:dry-run,只打印将执行的命令,不真删。

主要选项:
  --apply                     真执行(默认只打印)
  --restore-kube-proxy        强制恢复 kube-proxy(如果探测到 kube-proxy 不存在)
  --skip-kube-proxy-restore   跳过恢复 kube-proxy(只在确定要立即装别的 CNI 时用)
  --apiserver-host=HOST       恢复 kube-proxy 时用,默认从 kubeadm-config 探测
  --calico-version=VER        Calico 版本(必须跟当初装时一致,否则反向 delete 漏资源),默认 v3.28.2
  --force                     剥 finalizer 强删(namespace 卡 Terminating 时用)
  --keep-tigera-ns            卸载完不删 tigera-operator namespace
  -h, --help                  显示帮助

典型用法:
  # 看计划(强烈推荐先跑一遍)
  bash uninstall.sh

  # 完整卸载,恢复 kube-proxy
  bash uninstall.sh --apply

  # 要立即装 cilium,不恢复 kube-proxy
  bash uninstall.sh --apply --skip-kube-proxy-restore

  # namespace 卡 Terminating 强清
  bash uninstall.sh --apply --force
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
    --keep-tigera-ns) KEEP_TIGERA_NS="true" ;;
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

# 包装:dry-run 打印,--apply 真跑
run() {
  if [ "$APPLY" = "true" ]; then
    echo -e "  ${GREEN}\$${NC} $*"
    eval "$@"
  else
    echo -e "  ${YELLOW}[dry-run]${NC} $*"
  fi
}

# ============================================================
# 1/6 前置检查 + 现状盘点
# ============================================================
log "[1/6] 前置检查 + 现状盘点"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }

HAS_INSTALLATION=false
HAS_APISERVER_CR=false
HAS_TIGERA_NS=false
HAS_CALICO_NS=false
HAS_KUBE_PROXY=false

kubectl get installation default >/dev/null 2>&1 && HAS_INSTALLATION=true
kubectl get apiserver default >/dev/null 2>&1 && HAS_APISERVER_CR=true
kubectl get ns tigera-operator >/dev/null 2>&1 && HAS_TIGERA_NS=true
kubectl get ns calico-system >/dev/null 2>&1 && HAS_CALICO_NS=true
kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1 && HAS_KUBE_PROXY=true

echo
echo "  当前状态:"
echo "    Installation CR  : $HAS_INSTALLATION"
echo "    APIServer CR     : $HAS_APISERVER_CR"
echo "    tigera-operator ns: $HAS_TIGERA_NS"
echo "    calico-system ns : $HAS_CALICO_NS"
echo "    kube-proxy DS    : $HAS_KUBE_PROXY"
echo

if [ "$HAS_INSTALLATION" = "false" ] && [ "$HAS_TIGERA_NS" = "false" ] && [ "$HAS_CALICO_NS" = "false" ]; then
  ok "看起来 Calico 已经不在了,无需卸载"
  exit 0
fi

if [ "$APPLY" != "true" ]; then
  warn "DRY-RUN 模式,下面所有命令只打印不执行。确认 OK 后重跑 --apply。"
fi

# 决策:要不要恢复 kube-proxy?
RESTORE_DECISION="no"
if [ "$SKIP_KUBE_PROXY_RESTORE" = "true" ]; then
  warn "--skip-kube-proxy-restore:不恢复 kube-proxy。卸载后集群 Service 立即全断,确保你接下来要装别的 CNI"
  RESTORE_DECISION="no"
elif [ "$HAS_KUBE_PROXY" = "true" ]; then
  ok "kube-proxy 还在运行,无需恢复"
  RESTORE_DECISION="no"
elif [ "$RESTORE_KUBE_PROXY" = "true" ] || [ "$RESTORE_KUBE_PROXY" = "auto" ]; then
  warn "kube-proxy 已被删除,卸载 Calico 前需要先恢复它,否则集群网络立即全断"
  RESTORE_DECISION="yes"
fi

# ============================================================
# 2/6 恢复 kube-proxy(如果需要)
# ============================================================
log "[2/6] 恢复 kube-proxy"

if [ "$RESTORE_DECISION" = "yes" ]; then
  # 探测 API server 地址
  if [ -z "$APISERVER_HOST" ]; then
    APISERVER_HOST=$(kubectl -n kube-system get cm kubeadm-config -o yaml 2>/dev/null \
      | grep -oE 'controlPlaneEndpoint: [^[:space:]]+' | head -1 | awk '{print $2}' | cut -d: -f1 || true)
    if [ -z "$APISERVER_HOST" ]; then
      APISERVER_HOST=$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
    fi
  fi
  if [ -z "$APISERVER_HOST" ]; then
    err "无法探测 API server 地址,请显式 --apiserver-host=<HOST>"
    exit 1
  fi
  ok "API server: $APISERVER_HOST(用于恢复 kube-proxy)"

  if ! command -v kubeadm >/dev/null 2>&1; then
    warn "本机没有 kubeadm 二进制,无法自动恢复 kube-proxy"
    warn "请在 master 节点手动执行:"
    echo "    kubeadm init phase addon kube-proxy \\"
    echo "      --apiserver-advertise-address=$APISERVER_HOST \\"
    echo "      --pod-network-cidr=\$(kubectl -n kube-system get cm kubeadm-config -o yaml | grep podSubnet | awk '{print \$2}')"
    echo
    err "kube-proxy 没恢复,继续卸载会断网。Ctrl-C 中止 / 手动恢复后重跑本脚本"
    exit 1
  fi

  POD_CIDR=$(kubectl -n kube-system get cm kubeadm-config -o yaml 2>/dev/null \
    | grep -oE 'podSubnet: [0-9./,]+' | awk '{print $2}' | head -1)
  ok "Pod CIDR: $POD_CIDR"

  run "kubeadm init phase addon kube-proxy --apiserver-advertise-address=$APISERVER_HOST --pod-network-cidr=$POD_CIDR"

  if [ "$APPLY" = "true" ]; then
    log "  等 kube-proxy DaemonSet ready..."
    kubectl -n kube-system rollout status ds/kube-proxy --timeout=180s
    ok "kube-proxy 已恢复"
  fi
else
  log "  跳过(kube-proxy 还在 / 用户显式跳过)"
fi

# ============================================================
# 3/6 删 Installation CR + APIServer CR
# 删 CR 后 operator 会自动清理 calico-system 下所有资源
# ============================================================
log "[3/6] 删 Installation / APIServer CR"

if [ "$HAS_APISERVER_CR" = "true" ]; then
  run "kubectl delete apiserver default --ignore-not-found --timeout=120s"
fi
if [ "$HAS_INSTALLATION" = "true" ]; then
  run "kubectl delete installation default --ignore-not-found --timeout=120s"
fi

# Force 模式:剥 finalizer 应对卡 Terminating
if [ "$FORCE" = "true" ] && [ "$APPLY" = "true" ]; then
  for cr in installation apiserver; do
    if kubectl get $cr default >/dev/null 2>&1; then
      warn "$cr/default 卡 Terminating,剥 finalizer"
      kubectl patch $cr default --type=merge -p '{"metadata":{"finalizers":null}}' || true
    fi
  done
fi

ok "CR 删除请求已发出"

# ============================================================
# 4/6 等 calico-system 清理完
# ============================================================
log "[4/6] 等 calico-system 资源消失(最多 5 分钟)"

if [ "$APPLY" = "true" ] && [ "$HAS_CALICO_NS" = "true" ]; then
  for i in $(seq 1 60); do
    if ! kubectl get ns calico-system >/dev/null 2>&1; then
      ok "calico-system namespace 已消失"
      break
    fi
    POD_COUNT=$(kubectl -n calico-system get pods --no-headers 2>/dev/null | wc -l)
    if [ "$POD_COUNT" = "0" ]; then
      ok "calico-system 内 Pod 已全部删除"
      break
    fi
    sleep 5
    if [ $((i % 6)) -eq 0 ]; then
      log "  ...还在清理(已等 $((i*5)) 秒,剩余 $POD_COUNT 个 Pod)"
    fi
  done

  # 还卡着就 force
  if [ "$FORCE" = "true" ] && kubectl get ns calico-system >/dev/null 2>&1; then
    warn "calico-system 卡 Terminating,剥 finalizer"
    kubectl get ns calico-system -o json | \
      python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" | \
      kubectl replace --raw "/api/v1/namespaces/calico-system/finalize" -f - || true
  fi
else
  log "  跳过(dry-run 或 calico-system 本来就没了)"
fi

# ============================================================
# 5/6 反向 delete tigera-operator.yaml
# ============================================================
log "[5/6] 卸载 tigera-operator 本体"

NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"
TIGERA_OP_URL="${NEXUS_RAW}/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
TMP_OP=$(mktemp /tmp/tigera-operator.XXXXXX.yaml)
trap "rm -f $TMP_OP" EXIT

log "  拉取 $TIGERA_OP_URL(用于反向 delete)"
if [ "$APPLY" = "true" ]; then
  if ! curl -fsSLk "$TIGERA_OP_URL" -o "$TMP_OP"; then
    warn "下载 tigera-operator.yaml 失败,手动 delete:"
    echo "  kubectl -n tigera-operator delete deploy tigera-operator"
    echo "  kubectl delete crd installations.operator.tigera.io apiservers.operator.tigera.io \\"
    echo "    imagesets.operator.tigera.io tigerastatuses.operator.tigera.io"
  else
    ok "下载成功"
    run "kubectl delete -f $TMP_OP --ignore-not-found --timeout=180s"
  fi
else
  warn "[dry-run] 会下载 $TIGERA_OP_URL 后反向 delete"
  echo "    kubectl delete -f <tigera-operator.yaml> --ignore-not-found"
fi

# 删 kubernetes-services-endpoint ConfigMap(operator 创建的辅助资源)
if [ "$HAS_TIGERA_NS" = "true" ]; then
  run "kubectl -n tigera-operator delete cm kubernetes-services-endpoint --ignore-not-found"
fi

# 删 tigera-operator namespace
if [ "$KEEP_TIGERA_NS" = "true" ]; then
  warn "--keep-tigera-ns,保留 tigera-operator namespace"
elif [ "$HAS_TIGERA_NS" = "true" ]; then
  run "kubectl delete ns tigera-operator --ignore-not-found --timeout=120s"

  if [ "$FORCE" = "true" ] && [ "$APPLY" = "true" ] && kubectl get ns tigera-operator >/dev/null 2>&1; then
    warn "tigera-operator 卡 Terminating,剥 finalizer"
    kubectl get ns tigera-operator -o json | \
      python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" | \
      kubectl replace --raw "/api/v1/namespaces/tigera-operator/finalize" -f - || true
  fi
fi

# ============================================================
# 6/6 节点残留清理提示
# ============================================================
log "[6/6] 节点残留清理(每个 node 手动执行)"

NODES=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

cat <<EOF

每个节点(包括 master)需要清理以下残留:

  # 1. iptables KUBE-/CALI- 链
  iptables-save | grep -vE '^(:|-A )(KUBE|CALI|cali|kube)' | iptables-restore
  ip6tables-save | grep -vE '^(:|-A )(KUBE|CALI|cali|kube)' | ip6tables-restore 2>/dev/null

  # 2. ipvs(如果之前是 ipvs 模式)
  ipvsadm -C 2>/dev/null

  # 3. CNI 配置 + 二进制
  rm -f /etc/cni/net.d/*calico*
  rm -f /etc/cni/net.d/*tigera*
  rm -f /opt/cni/bin/calico /opt/cni/bin/calico-ipam

  # 4. Calico 残留目录
  rm -rf /var/lib/calico
  rm -rf /var/log/calico
  rm -rf /var/run/calico

  # 5. BPF 程序(eBPF 模式装的)
  bpftool prog list 2>/dev/null | grep -B1 calico
  # 看到 calico 相关程序就 detach:
  # tc filter del dev <iface> ingress
  # tc filter del dev <iface> egress
  # 简单粗暴:重启节点最干净

节点列表:
EOF

if [ -n "$NODES" ]; then
  for ip in $NODES; do echo "  - $ip"; done
fi

cat <<EOF

可以打包成一行(在每个 node 上 root 执行):

  ssh root@<node-ip> '
    iptables-save | grep -vE "^(:|-A )(KUBE|CALI|cali|kube)" | iptables-restore
    rm -f /etc/cni/net.d/*calico* /etc/cni/net.d/*tigera* /opt/cni/bin/calico*
    rm -rf /var/lib/calico /var/log/calico /var/run/calico
  '

【强烈建议】卸载完成后重启所有节点一次,清除 BPF 程序和内核 conntrack 残留。

EOF

if [ "$APPLY" != "true" ]; then
  echo
  warn "以上是 DRY-RUN,确认计划没问题后跑:"
  echo "    bash $0 --apply"
fi

log "==== 完成 ===="
