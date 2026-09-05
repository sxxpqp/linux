#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — NodeLocal DNSCache / kube-proxy IPVS 模式
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/nodelocaldns/install-ipvs.sh
# 用法: curl -sL <URL> -o install-ipvs.sh && bash install-ipvs.sh [选项]

set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_YAML="${SCRIPT_DIR}/nodelocaldns.yaml"
DOMAIN="${DOMAIN:-cluster.local}"
LOCAL_DNS="${LOCAL_DNS:-169.254.20.10}"
NAMESPACE="kube-system"
DRY_RUN="false"
OUTPUT=""

usage() {
  cat <<'EOF'
用法: bash install-ipvs.sh [选项]

说明:
  kube-proxy IPVS 模式下，kube-dns Service IP 已被 kube-ipvs0 占用，
  node-local-dns 只能监听本地 DNS IP: 169.254.20.10(默认)。
  安装后需要把 kubelet --cluster-dns 改成该本地 DNS IP，并重建业务 Pod 才生效。

可选:
  --local-dns=IP     NodeLocal DNSCache 本地监听 IP，默认 169.254.20.10
  --domain=DOMAIN    集群 DNS 域，默认 cluster.local
  --output=FILE      只生成渲染后的 YAML 到 FILE，不 apply
  --dry-run          打印 kubectl server-side dry-run，不落集群
  -h, --help         显示帮助

环境变量:
  LOCAL_DNS          同 --local-dns
  DOMAIN             同 --domain

示例:
  bash install-ipvs.sh
  bash install-ipvs.sh --local-dns=169.254.20.10 --domain=cluster.local
  bash install-ipvs.sh --output=/tmp/nodelocaldns-ipvs.yaml
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --local-dns=*) LOCAL_DNS="${1#*=}" ;;
    --domain=*) DOMAIN="${1#*=}" ;;
    --output=*) OUTPUT="${1#*=}" ;;
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

log "[1/4] 前置检查"
command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
ok "kubectl 可用"

if [ ! -f "$SRC_YAML" ]; then
  err "找不到模板: $SRC_YAML"
  exit 1
fi
ok "模板: $SRC_YAML"

COREDNS_IP="$(kubectl -n "$NAMESPACE" get svc kube-dns -o jsonpath='{.spec.clusterIP}')"
if [ -z "$COREDNS_IP" ] || [ "$COREDNS_IP" = "None" ]; then
  err "无法读取 kube-system/kube-dns Service ClusterIP"
  exit 1
fi
ok "kube-dns Service IP: $COREDNS_IP"
ok "local DNS IP: $LOCAL_DNS"
ok "cluster domain: $DOMAIN"

MODE="$(kubectl -n "$NAMESPACE" get cm kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -E '^[[:space:]]*mode:' | sed -E 's/^[[:space:]]*mode:[[:space:]]*"?([^"[:space:]]*)"?.*/\1/' || true)"
if [ -n "$MODE" ] && [ "$MODE" != "ipvs" ]; then
  warn "kube-proxy ConfigMap mode=${MODE}，当前脚本是 IPVS 模式；如果实际跑 iptables，请用 install-iptables.sh"
fi

log "[2/4] 渲染 IPVS 模式 YAML"
WORK_DIR="$(mktemp -d /tmp/nodelocaldns-ipvs.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
RENDERED="${WORK_DIR}/nodelocaldns-ipvs.yaml"
cp "$SRC_YAML" "$RENDERED"

sed -i \
  -e "s/__PILLAR__LOCAL__DNS__/${LOCAL_DNS}/g" \
  -e "s/__PILLAR__DNS__DOMAIN__/${DOMAIN}/g" \
  -e 's/,__PILLAR__DNS__SERVER__//g' \
  -e 's/ __PILLAR__DNS__SERVER__//g' \
  -e "s/__PILLAR__CLUSTER__DNS__/${COREDNS_IP}/g" \
  "$RENDERED"

if grep -qE '__PILLAR__LOCAL__DNS__|__PILLAR__DNS__DOMAIN__|__PILLAR__DNS__SERVER__|__PILLAR__CLUSTER__DNS__' "$RENDERED"; then
  err "仍有 IPVS 模式必替换占位符未处理"
  grep -nE '__PILLAR__LOCAL__DNS__|__PILLAR__DNS__DOMAIN__|__PILLAR__DNS__SERVER__|__PILLAR__CLUSTER__DNS__' "$RENDERED" >&2 || true
  exit 1
fi
ok "已渲染: $RENDERED"

if [ -n "$OUTPUT" ]; then
  cp "$RENDERED" "$OUTPUT"
  ok "已输出: $OUTPUT"
  exit 0
fi

log "[3/4] 部署 NodeLocal DNSCache"
if [ "$DRY_RUN" = "true" ]; then
  kubectl apply --dry-run=server -f "$RENDERED"
  ok "server-side dry-run 通过，未落集群"
else
  kubectl apply -f "$RENDERED"
  ok "已 apply"
fi

log "[4/4] 等待 DaemonSet 就绪"
if [ "$DRY_RUN" = "true" ]; then
  warn "dry-run 模式跳过 rollout status"
else
  kubectl -n "$NAMESPACE" rollout status ds/node-local-dns --timeout=300s
  ok "node-local-dns DaemonSet Ready"
fi

cat <<EOF

完成: NodeLocal DNSCache IPVS 模式

必须做:
  1. 把每个节点 kubelet 的 --cluster-dns 改成 ${LOCAL_DNS}
  2. 重启 kubelet
  3. 重建业务 Pod，让 /etc/resolv.conf 写入 ${LOCAL_DNS}

验证:
  kubectl -n kube-system get ds node-local-dns -o wide
  kubectl -n kube-system logs -l k8s-app=node-local-dns --tail=80
  kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default.svc.${DOMAIN}

说明:
  - IPVS 模式下 node-cache 只监听 ${LOCAL_DNS}
  - kube-dns Service IP ${COREDNS_IP} 由 kube-ipvs0 占用，不能再给 node-cache 绑定
EOF
