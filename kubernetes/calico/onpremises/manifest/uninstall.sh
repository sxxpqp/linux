#!/usr/bin/env bash
# 系统: Kubernetes (K8s)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/onpremises/manifest/uninstall.sh
# 用法: curl -sL <URL> -o uninstall.sh && bash uninstall.sh [选项]
#
# 卸载 manifest 方式装的 Calico(单 calico.yaml,跑在 kube-system)。
# 默认 dry-run,加 --apply 才真删。
#
# 反向卸载 install.sh 装过的内容,不做额外动作:
#   1. 反向 delete calico.yaml(整套删:DS / Deploy / CRD / RBAC)
#   2. 删 kubernetes-services-endpoint ConfigMap(eBPF 模式才有,没有忽略)
#   3. 打印节点残留清理命令
#
# 不包含:kube-proxy 恢复 / dataplane 切换 / namespace force 清理(需要自己手动)

set -euo pipefail

# ============================================================
# 默认值 / 参数解析
# ============================================================
CALICO_VERSION="v3.28.2"
APPLY="false"
FORCE="false"

usage() {
  cat <<'EOF'
用法: bash uninstall.sh [选项]

默认 dry-run。加 --apply 才真删。

选项:
  --apply                 真执行
  --calico-version=VER    Calico 版本(必须跟装时一致),默认 v3.28.2
  --force                 残留 CRD 资源剥 finalizer
  -h, --help              显示帮助

示例:
  bash uninstall.sh                          # 看计划
  bash uninstall.sh --apply                  # 真删
  bash uninstall.sh --apply --force          # CRD 卡 Terminating 时用
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="true" ;;
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
# 1/3 前置检查
# ============================================================
log "[1/3] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }

if ! kubectl -n kube-system get ds calico-node >/dev/null 2>&1; then
  ok "kube-system 没有 calico-node DS,看起来已经卸载干净"
  warn "如果是 operator 方式装的,请用 operator/uninstall.sh"
  exit 0
fi

[ "$APPLY" != "true" ] && warn "DRY-RUN 模式,只打印不执行"

# ============================================================
# 2/3 反向 delete calico.yaml + ConfigMap
# ============================================================
log "[2/3] 反向 delete calico.yaml"

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
    exit 1
  fi
  run "kubectl delete -f $TMP_YAML --ignore-not-found --timeout=180s"
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

# eBPF 模式装的辅助 ConfigMap,calico-node 删完之后删它才安全
run "kubectl -n kube-system delete cm kubernetes-services-endpoint --ignore-not-found"

# ============================================================
# 3/3 节点残留清理提示
# ============================================================
log "[3/3] 节点残留清理(每个 node 手动执行)"

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
