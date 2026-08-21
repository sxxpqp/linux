#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — 卸载 sig-storage-local-static-provisioner(Local PV 静态发现)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/local-static-provisioner/uninstall.sh
# 用法: curl -sL <URL> -o uninstall.sh && bash uninstall.sh [选项]
#
# 说明:
#   - 默认 dry-run,加 --apply 才真删
#   - 默认只卸载 Helm release / namespace 内组件,不删节点本地数据
#   - 不自动删 PV/PVC/节点本地目录,危险动作需显式参数开启

set -euo pipefail

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

NAMESPACE="local-storage"
RELEASE_NAME="provisioner"
STORAGE_CLASS_NAME="local-ssd"
NODE_LABEL_KEY="local-storage"
NODE_LABEL_VALUE="ssd"
DELETE_STORAGECLASS="false"
DELETE_TEST_PVC="false"
REMOVE_NODE_LABELS="false"
APPLY="false"
WAIT_TIMEOUT="180s"

usage() {
  cat <<'EOF'
用法: bash uninstall.sh [选项]

默认 dry-run。加 --apply 才真删。

选项:
  --apply                     真执行
  --namespace=NAME           Namespace,默认 local-storage
  --release=NAME             Helm release 名,默认 provisioner
  --storage-class=NAME       StorageClass 名,默认 local-ssd
  --node-label=K=V           节点标签,默认 local-storage=ssd
  --delete-storageclass      同时删除 StorageClass
  --delete-test-pvc          同时删除 local-ssd-test-pvc / local-ssd-test-pod
  --remove-node-labels       同时移除目标节点上的标签
  --wait-timeout=180s        删除等待超时,默认 180s
  -h, --help                 显示帮助

示例:
  bash uninstall.sh
  bash uninstall.sh --apply
  bash uninstall.sh --apply --delete-storageclass --delete-test-pvc
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY="true" ;;
    --namespace=*) NAMESPACE="${1#*=}" ;;
    --release=*) RELEASE_NAME="${1#*=}" ;;
    --storage-class=*) STORAGE_CLASS_NAME="${1#*=}" ;;
    --node-label=*)
      LABEL_PAIR="${1#*=}"
      if ! printf '%s' "$LABEL_PAIR" | grep -q '='; then
        echo "ERROR: --node-label 需要 K=V 格式,例如 local-storage=ssd" >&2
        exit 1
      fi
      NODE_LABEL_KEY="${LABEL_PAIR%%=*}"
      NODE_LABEL_VALUE="${LABEL_PAIR#*=}"
      ;;
    --delete-storageclass) DELETE_STORAGECLASS="true" ;;
    --delete-test-pvc) DELETE_TEST_PVC="true" ;;
    --remove-node-labels) REMOVE_NODE_LABELS="true" ;;
    --wait-timeout=*) WAIT_TIMEOUT="${1#*=}" ;;
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
run() {
  if [ "$APPLY" = "true" ]; then
    echo -e "  ${GREEN}\$${NC} $*"
    eval "$@"
  else
    echo -e "  ${YELLOW}[dry-run]${NC} $*"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log "[1/5] 前置检查"
command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
command -v helm >/dev/null || { err "helm 不存在"; exit 1; }
ok "kubectl / helm 可用"
[ "$APPLY" != "true" ] && warn "DRY-RUN 模式,只打印不执行"
warn "默认不会删除节点本地目录/数据,例如 /mnt/disks/*"
warn "默认不会删除已有 PV/PVC,避免误删本地数据映射"

log "[2/5] 删除测试资源(可选)"
if [ "$DELETE_TEST_PVC" = "true" ]; then
  run "kubectl -n ${NAMESPACE} delete pod local-ssd-test-pod --ignore-not-found --wait=false"
  run "kubectl -n ${NAMESPACE} delete pvc local-ssd-test-pvc --ignore-not-found --timeout=${WAIT_TIMEOUT}"
else
  warn "跳过测试 PVC/Pod 删除(如需删除加 --delete-test-pvc)"
fi

log "[3/5] 卸载 Helm release"
if [ "$APPLY" = "true" ] && helm -n "$NAMESPACE" status "$RELEASE_NAME" >/dev/null 2>&1; then
  run "helm uninstall ${RELEASE_NAME} -n ${NAMESPACE} --ignore-not-found"
else
  run "helm uninstall ${RELEASE_NAME} -n ${NAMESPACE} --ignore-not-found"
fi

if [ "$APPLY" = "true" ] && kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  if kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | grep -q .; then
    log "  等 ${NAMESPACE} namespace 下 Pod 终止(最多 30s)..."
    kubectl -n "$NAMESPACE" wait --for=delete pod --all --timeout=30s 2>/dev/null || true
  fi
fi

log "[4/5] 删除 StorageClass / 节点标签(可选)"
if [ "$DELETE_STORAGECLASS" = "true" ]; then
  run "kubectl delete sc ${STORAGE_CLASS_NAME} --ignore-not-found --timeout=${WAIT_TIMEOUT}"
else
  warn "跳过 StorageClass 删除(如需删除加 --delete-storageclass)"
fi

if [ "$REMOVE_NODE_LABELS" = "true" ]; then
  MATCHED_NODES=$(kubectl get nodes -l "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" -o name 2>/dev/null || true)
  if [ -n "$MATCHED_NODES" ]; then
    for node in $MATCHED_NODES; do
      run "kubectl label ${node} ${NODE_LABEL_KEY}-"
    done
  else
    warn "未找到 ${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} 标签节点"
  fi
else
  warn "跳过节点标签删除(如需删除加 --remove-node-labels)"
fi

if [ "$APPLY" = "true" ] && kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  POD_LEFT=$(kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$POD_LEFT" = "0" ]; then
    run "kubectl delete ns ${NAMESPACE} --ignore-not-found --timeout=${WAIT_TIMEOUT}"
  else
    warn "${NAMESPACE} 里还有 Pod,跳过删 namespace"
  fi
fi

if [ "$APPLY" = "true" ] && kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  NS_PHASE=$(kubectl get ns "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$NS_PHASE" = "Terminating" ]; then
    warn "namespace ${NAMESPACE} 卡在 Terminating,尝试清理 finalizer"
    kubectl patch ns "$NAMESPACE" --type=json -p '[{"op":"remove","path":"/spec/finalizers"}]' 2>/dev/null || true
  fi
fi

log "[5/5] 验证"
if [ "$APPLY" = "true" ]; then
  helm -n "$NAMESPACE" list 2>/dev/null | grep "$RELEASE_NAME" || true
  kubectl -n "$NAMESPACE" get pods -o wide 2>/dev/null || true
  kubectl get sc "$STORAGE_CLASS_NAME" 2>/dev/null || true
  kubectl get pv 2>/dev/null | grep "$STORAGE_CLASS_NAME" || true
fi

echo
log "==== 完成 ===="
if [ "$APPLY" != "true" ]; then
  warn "以上是 DRY-RUN,确认后跑: bash $0 --apply"
fi
echo "保留说明:"
echo "  - 节点本地目录和数据不会自动删除"
echo "  - 已发现的 PV 不会自动删除"
echo "  - StorageClass / 测试 PVC / 节点标签只有显式参数才会删除"
