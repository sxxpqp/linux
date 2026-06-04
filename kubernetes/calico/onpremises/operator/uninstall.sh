#!/usr/bin/env bash
# 系统: Kubernetes (K8s)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/onpremises/operator/uninstall.sh
# 用法: curl -sL <URL> -o uninstall.sh && bash uninstall.sh [选项]
#
# 卸载 Tigera Operator 部署的 Calico。默认 dry-run,加 --apply 才真删。
#
# 反向卸载 install.sh 装过的内容,不做额外动作:
#   1. 剥 Installation + APIServer CR finalizer → delete CR
#   2. 剥 calico-system ns finalizer → 等 ns 消失
#   3. 删 kubernetes-services-endpoint ConfigMap(必须在 tigera-operator ns 还活着时删)
#   4. 反向 delete tigera-operator.yaml(一次性带走 ns + operator + RBAC + CRDs)
#   5. 兜底剥 tigera-operator ns finalizer → delete ns + 节点残留清理命令
#
# 设计原则:
#   - 卸载 = "我就是要它没"。每一步删除前都先剥 finalizer,不等 operator 慢慢清,
#     避免 operator 中间态 / 卡 Terminating 把脚本挂死。代价是 calico-system 内可能有
#     极少量孤儿资源(operator 清不完),但 ns 强删时会一起带走。
#   - 删除顺序依赖:
#     · 先剥 CR finalizer 再 delete:CR 上的 finalizer 是 operator/uninstall-controller,
#       operator 自己也快没了,等它处理就是死等
#     · 先删 cm 再删 operator yaml:tigera-operator.yaml 第一个对象就是 Namespace,
#       kubectl delete 一删 ns 里面的 cm 跟着没,后面单独 delete cm 就成无意义动作
#     · 先 CR 后 CRD:CR 还在时删 CRD 会触发 cascade,把 finalizer 流程搅乱
#
# 不包含:kube-proxy 恢复 / dataplane 切换(需要自己手动)

set -euo pipefail

# ============================================================
# 默认值 / 参数解析
# ============================================================
CALICO_VERSION="v3.28.2"
APPLY="false"
KEEP_TIGERA_NS="false"

usage() {
  cat <<'EOF'
用法: bash uninstall.sh [选项]

默认 dry-run。加 --apply 才真删。
卸载流程已经默认"删除前先剥 finalizer",不会卡 Terminating,所以没有 --force 选项。

选项:
  --apply                 真执行
  --calico-version=VER    Calico 版本(必须跟装时一致),默认 v3.28.2
  --keep-tigera-ns        卸载完不删 tigera-operator namespace
  -h, --help              显示帮助

示例:
  bash uninstall.sh                       # 看计划
  bash uninstall.sh --apply               # 真删
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="true" ;;
    --calico-version=*) CALICO_VERSION="${1#*=}" ;;
    --force) warn "--force 已废弃(默认就剥 finalizer 强删),自动忽略" ;;
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

run() {
  if [ "$APPLY" = "true" ]; then
    echo -e "  ${GREEN}\$${NC} $*"
    eval "$@"
  else
    echo -e "  ${YELLOW}[dry-run]${NC} $*"
  fi
}

# ============================================================
# 1/4 前置检查
# ============================================================
log "[1/4] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }

HAS_INSTALLATION=false
HAS_APISERVER_CR=false
HAS_TIGERA_NS=false
HAS_CALICO_NS=false

kubectl get installation default >/dev/null 2>&1 && HAS_INSTALLATION=true
kubectl get apiserver default >/dev/null 2>&1 && HAS_APISERVER_CR=true
kubectl get ns tigera-operator >/dev/null 2>&1 && HAS_TIGERA_NS=true
kubectl get ns calico-system >/dev/null 2>&1 && HAS_CALICO_NS=true

if [ "$HAS_INSTALLATION" = "false" ] && [ "$HAS_TIGERA_NS" = "false" ] && [ "$HAS_CALICO_NS" = "false" ]; then
  ok "看起来 Calico 已经不在了,无需卸载"
  exit 0
fi

[ "$APPLY" != "true" ] && warn "DRY-RUN 模式,只打印不执行"

# ============================================================
# 2/4 删 Installation / APIServer CR
# 卸载语义就是"我要它没",finalizer 卡 Terminating 的话 delete 会阻塞 60s+,
# 所以默认就是"先剥 finalizer 再 delete",不再用 --force 门控
# ============================================================
log "[2/4] 删 Installation / APIServer CR"

if [ "$APPLY" = "true" ]; then
  for cr in apiserver installation; do
    if kubectl get $cr default >/dev/null 2>&1; then
      log "  剥 $cr/default finalizer"
      kubectl patch $cr default --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    fi
  done
fi

if [ "$HAS_APISERVER_CR" = "true" ]; then
  run "kubectl delete apiserver default --ignore-not-found --timeout=30s"
fi
if [ "$HAS_INSTALLATION" = "true" ]; then
  run "kubectl delete installation default --ignore-not-found --timeout=30s"
fi

# ============================================================
# 3/4 等 calico-system 清完 → 删 cm → 反向 delete tigera-operator.yaml → 兜底删 ns
# 顺序原因见文件开头注释
# ============================================================
log "[3/4] 处理 calico-system namespace"

# 先剥 finalizer(同样不门控 --force,卸载就是要它没)
# operator 已经被剥 finalizer + 删除中,calico-system 的 ns finalizer 也很可能没人来清,
# 不剥的话等 5 分钟就是浪费
if [ "$APPLY" = "true" ] && [ "$HAS_CALICO_NS" = "true" ]; then
  if kubectl get ns calico-system >/dev/null 2>&1; then
    log "  剥 calico-system ns finalizer"
    kubectl get ns calico-system -o json | \
      python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" | \
      kubectl replace --raw "/api/v1/namespaces/calico-system/finalize" -f - 2>/dev/null || true
  fi

  # 等最多 30 秒让 ns 真正消失(剥了 finalizer 一般几秒就没)
  for i in $(seq 1 6); do
    if ! kubectl get ns calico-system >/dev/null 2>&1; then
      ok "calico-system namespace 已消失"
      break
    fi
    sleep 5
    [ $i -eq 6 ] && warn "calico-system 30 秒后仍在,继续往下走"
  done
fi

# 必须在 tigera-operator ns 还活着时删 cm,
# 否则后面 delete -f tigera-operator.yaml 会一并干掉 ns,cm 就找不到了
if [ "$HAS_TIGERA_NS" = "true" ]; then
  log "  删 kubernetes-services-endpoint ConfigMap(趁 ns 还在)"
  run "kubectl -n tigera-operator delete cm kubernetes-services-endpoint --ignore-not-found"
fi

# 先把 operator deployment 杀掉,后面再清 RBAC 才不会被边删边重建
log "  先 scale operator deployment 到 0(防止 RBAC 边删边重建)"
if kubectl -n tigera-operator get deploy tigera-operator >/dev/null 2>&1; then
  run "kubectl -n tigera-operator scale deploy tigera-operator --replicas=0 --timeout=30s"
fi

# 先清残留 webhook(backend service 一旦死,webhook 会拦后续 admission,
# 导致 kubectl 显示 "deleted" 但 API 实际拒绝;表现为资源持续存在且 creationTimestamp 不变)
log "  清残留 admission webhook(防止 backend 死后拦后续 API 调用)"
if [ "$APPLY" = "true" ]; then
  kubectl get validatingwebhookconfigurations -o name 2>/dev/null \
    | grep -iE 'calico|tigera|operator' | xargs -r kubectl delete --wait=false 2>/dev/null || true
  kubectl get mutatingwebhookconfigurations -o name 2>/dev/null \
    | grep -iE 'calico|tigera|operator' | xargs -r kubectl delete --wait=false 2>/dev/null || true
else
  warn "[dry-run] 会清 validating/mutating webhook 中含 calico/tigera/operator 的"
fi

log "  反向 delete tigera-operator.yaml(含 ns + operator + RBAC + CRDs)"
NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"
TIGERA_OP_URL="${NEXUS_RAW}/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
TMP_OP=$(mktemp /tmp/tigera-operator.XXXXXX.yaml)
trap "rm -f $TMP_OP" EXIT

log "  拉取 $TIGERA_OP_URL"
if [ "$APPLY" = "true" ]; then
  if ! curl -fsSLk "$TIGERA_OP_URL" -o "$TMP_OP"; then
    warn "下载 tigera-operator.yaml 失败,手动 delete:"
    echo "    kubectl -n tigera-operator delete deploy tigera-operator"
    echo "    kubectl delete crd installations.operator.tigera.io apiservers.operator.tigera.io \\"
    echo "      imagesets.operator.tigera.io tigerastatuses.operator.tigera.io"
    echo "    kubectl delete ns tigera-operator"
  else
    run "kubectl delete -f $TMP_OP --ignore-not-found --timeout=180s"
  fi
else
  warn "[dry-run] 会下载 $TIGERA_OP_URL 后反向 delete"
fi

# operator 运行时动态创建的 cluster-scoped RBAC,不在 tigera-operator.yaml 里。
# 必须放在 delete -f tigera-operator.yaml 之后,否则 operator 还活着会边删边重建。
# --wait=false:RBAC 删除是纯 API call,不需要等 watch 确认(等的话偶尔会卡几十秒)
log "  清 operator 创建的 cluster-scoped RBAC 残留"
run "kubectl delete clusterrole calico-kube-controllers calico-node calico-cni-plugin --ignore-not-found --wait=false 2>/dev/null"
run "kubectl delete clusterrolebinding calico-kube-controllers calico-node calico-cni-plugin --ignore-not-found --wait=false 2>/dev/null"

# 兜底:yaml delete 没把 ns 删干净时,这里强制清掉(剥 finalizer 再 delete)
if [ "$KEEP_TIGERA_NS" = "true" ]; then
  warn "--keep-tigera-ns,保留 tigera-operator namespace"
elif [ "$APPLY" = "true" ] && kubectl get ns tigera-operator >/dev/null 2>&1; then
  warn "tigera-operator namespace 还在(yaml delete 没删干净),兜底强清"
  log "  剥 tigera-operator ns finalizer"
  kubectl get ns tigera-operator -o json | \
    python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" | \
    kubectl replace --raw "/api/v1/namespaces/tigera-operator/finalize" -f - 2>/dev/null || true
  run "kubectl delete ns tigera-operator --ignore-not-found --timeout=30s"
fi

# 等到 ns 真正消失再退出(避免立刻重装时撞 Terminating)
if [ "$APPLY" = "true" ] && [ "$KEEP_TIGERA_NS" != "true" ]; then
  log "  等 tigera-operator namespace 真正消失(最多 2 分钟)"
  for i in $(seq 1 24); do
    if ! kubectl get ns tigera-operator >/dev/null 2>&1; then
      ok "tigera-operator namespace 已消失"
      break
    fi
    sleep 5
    [ $((i % 6)) -eq 0 ] && log "  ...还在 Terminating(已等 $((i*5)) 秒,加 --force 试试)"
  done
fi

# 最终残留检查 — 列出来,用户清楚之后能不能直接重装
log "  最终残留检查"
LEFTOVER=""
for cr in installation apiserver; do
  if kubectl get $cr default >/dev/null 2>&1; then
    LEFTOVER="$LEFTOVER\n    - $cr/default 还在"
  fi
done
for ns in calico-system tigera-operator calico-apiserver; do
  if kubectl get ns $ns >/dev/null 2>&1; then
    LEFTOVER="$LEFTOVER\n    - ns/$ns 还在"
  fi
done
for wh in $(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null | grep -iE 'calico|tigera|operator'); do
  LEFTOVER="$LEFTOVER\n    - $wh 还在(会拦后续 admission)"
done
for role in calico-kube-controllers calico-node calico-cni-plugin tigera-operator; do
  if kubectl get clusterrole $role >/dev/null 2>&1; then
    LEFTOVER="$LEFTOVER\n    - clusterrole/$role 还在"
  fi
done
if [ -n "$LEFTOVER" ]; then
  warn "发现残留(重装会踩坑,建议先清):"
  echo -e "$LEFTOVER"
  warn "  快速清理:"
  echo "    kubectl delete clusterrole,clusterrolebinding calico-kube-controllers calico-node calico-cni-plugin tigera-operator 2>/dev/null"
  echo "    bash $0 --apply --force"
else
  ok "无残留,可以直接重装"
fi

# ============================================================
# 4/4 节点残留清理提示
# ============================================================
log "[4/4] 节点残留清理(每个 node 手动执行)"

NODES=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "")

cat <<EOF

每个节点(包括 master)需要清理:

  # 1. iptables KUBE-/CALI- 链
  iptables-save | grep -vE '^(:|-A )(KUBE|CALI|cali|kube)' | iptables-restore
  ip6tables-save | grep -vE '^(:|-A )(KUBE|CALI|cali|kube)' | ip6tables-restore 2>/dev/null

  # 2. ipvs
  ipvsadm -C 2>/dev/null

  # 3. CNI 配置 + 二进制
  rm -f /etc/cni/net.d/*calico* /etc/cni/net.d/*tigera*
  rm -f /opt/cni/bin/calico /opt/cni/bin/calico-ipam

  # 4. Calico 数据目录
  rm -rf /var/lib/calico /var/log/calico /var/run/calico

  # 5. BPF 程序(开过 eBPF 才有)
  bpftool prog list 2>/dev/null | grep -B1 calico && echo "有残留,建议重启节点"

节点列表:
EOF

[ -n "$NODES" ] && for ip in $NODES; do echo "  - $ip"; done

cat <<EOF

【强烈建议】卸载完成后重启所有节点一次,清除内核 conntrack / BPF 残留。

EOF

[ "$APPLY" != "true" ] && warn "以上是 DRY-RUN,确认后跑: bash $0 --apply"

log "==== 完成 ===="
