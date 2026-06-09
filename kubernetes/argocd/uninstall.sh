#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — 卸载 ArgoCD
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/argocd/uninstall.sh
# 用法: bash uninstall.sh [选项]
#
# 反向删除 install.sh + install-v2.13.3.yaml 装的资源。默认 dry-run。
# 关键:Application/AppProject 带 finalizer,直删 ns 会卡 Terminating → 第 2 步先清。

set -euo pipefail

NAMESPACE="argocd"
YAML=""
APPLY="false"
KEEP_CRD="false"
KEEP_NS="false"

usage() {
  cat <<'EOF'
用法: bash uninstall.sh [选项]

默认 DRY-RUN,加 --apply 才真删。

选项:
  --namespace=NS    安装的 ns,默认 argocd
  --yaml=PATH       install yaml,默认 ./install-v2.13.3.yaml
  --apply           真执行
  --keep-crd        保留 3 个 argoproj.io CRD(默认删)
                    ⚠ 默认会连带删所有 Application/AppProject(K8s GC 机制),
                       --keep-crd 时本脚本会从集群备份 CRD 再 reapply
  --keep-ns         保留 namespace(默认删)
  -h, --help        显示帮助

示例:
  bash uninstall.sh                     # dry-run 看计划
  bash uninstall.sh --apply             # 全删:Application + 组件 + CRD + ns
  bash uninstall.sh --apply --keep-crd  # 保留 CRD(方便后续 reinstall 不丢 scheme)
  bash uninstall.sh --apply --keep-ns   # 留 ns(留 logs / configmap 排错用)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace=*) NAMESPACE="${1#*=}" ;;
    --yaml=*) YAML="${1#*=}" ;;
    --apply) APPLY="true" ;;
    --keep-crd) KEEP_CRD="true" ;;
    --keep-ns) KEEP_NS="true" ;;
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
[ -z "$YAML" ] && YAML="${SCRIPT_DIR}/install-v2.13.3.yaml"
[[ "$YAML" != /* ]] && YAML="${SCRIPT_DIR}/${YAML}"

# ============================================================
# 1/5 前置检查
# ============================================================
log "[1/5] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }

HAS_NS=false; HAS_CRD=false
kubectl get ns "$NAMESPACE" >/dev/null 2>&1 && HAS_NS=true
kubectl get crd applications.argoproj.io >/dev/null 2>&1 && HAS_CRD=true

if [ "$HAS_NS" = "false" ] && [ "$HAS_CRD" = "false" ]; then
  ok "ns/$NAMESPACE + argoproj.io CRD 都不存在,已卸载干净"
  exit 0
fi

[ "$APPLY" != "true" ] && warn "DRY-RUN 模式,只打印不执行"

# ============================================================
# 2/5 清 Application / AppProject / ApplicationSet
# ============================================================
log "[2/5] 清 Application / AppProject / ApplicationSet"

if [ "$HAS_CRD" = "true" ]; then
  # Application(带 finalizer,先 patch 掉)
  APPS=$(kubectl get applications.argoproj.io -A --no-headers 2>/dev/null | wc -l | awk '{print $1}')
  if [ "${APPS:-0}" -gt 0 ]; then
    warn "发现 $APPS 个 Application,先清 finalizer 再删(否则 ns 会卡 Terminating)"
    if [ "$APPLY" = "true" ]; then
      # 一行一个 ns/name
      kubectl get applications.argoproj.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
        while read ns name; do
          [ -z "$ns" ] && continue
          kubectl -n "$ns" patch applications.argoproj.io "$name" \
            --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        done
      kubectl delete applications.argoproj.io --all -A --ignore-not-found --timeout=30s 2>/dev/null || true
    else
      echo "  [dry-run] 清 $APPS 个 Application finalizer + delete"
    fi
  else
    ok "无 Application"
  fi

  ASETS=$(kubectl get applicationsets.argoproj.io -A --no-headers 2>/dev/null | wc -l | awk '{print $1}')
  if [ "${ASETS:-0}" -gt 0 ]; then
    run "kubectl delete applicationsets.argoproj.io --all -A --ignore-not-found --timeout=30s"
  else
    ok "无 ApplicationSet"
  fi

  PROJS=$(kubectl get appprojects.argoproj.io -A --no-headers 2>/dev/null | wc -l | awk '{print $1}')
  if [ "${PROJS:-0}" -gt 0 ]; then
    run "kubectl delete appprojects.argoproj.io --all -A --ignore-not-found --timeout=30s"
  else
    ok "无 AppProject"
  fi
fi

# ============================================================
# 3/5 备份 CRD(--keep-crd) + delete -f install yaml
# ============================================================
log "[3/5] 删 install yaml 资源"

CRD_BACKUP=""
if [ "$KEEP_CRD" = "true" ] && [ "$APPLY" = "true" ] && [ "$HAS_CRD" = "true" ]; then
  CRD_BACKUP="/tmp/argocd-crd-backup.$$.yaml"
  log "  --keep-crd:先备份 CRD → $CRD_BACKUP"
  kubectl get crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io \
    -o yaml > "$CRD_BACKUP" 2>/dev/null || warn "CRD 备份失败,继续"
fi

if [ -f "$YAML" ]; then
  # delete -f 会一并删 CRD(yaml 包含 CRD)
  run "kubectl delete -n $NAMESPACE -f $YAML --ignore-not-found --timeout=120s"
else
  warn "yaml 不在 $YAML,改按 label 删"
  for k in deploy sts svc cm secret sa role rolebinding clusterrole clusterrolebinding netpol; do
    run "kubectl -n $NAMESPACE delete $k -l app.kubernetes.io/part-of=argocd --ignore-not-found --timeout=60s"
  done
fi

# 强清残留 Pod(StatefulSet 删完 controller-0 偶尔卡住)
if [ "$APPLY" = "true" ] && kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null | grep -q .; then
  kubectl -n "$NAMESPACE" delete pods --all --force --grace-period=0 --wait=false 2>/dev/null || true
fi

# ============================================================
# 4/5 CRD reapply / 删除
# ============================================================
log "[4/5] CRD"

if [ "$KEEP_CRD" = "true" ]; then
  if [ "$APPLY" = "true" ] && [ -n "$CRD_BACKUP" ] && [ -s "$CRD_BACKUP" ]; then
    log "  reapply CRD(从 $CRD_BACKUP)"
    kubectl apply -f "$CRD_BACKUP" >/dev/null 2>&1 && ok "3 个 CRD 已 reapply" || warn "CRD reapply 失败,手动: kubectl apply -f $CRD_BACKUP"
    rm -f "$CRD_BACKUP"
  else
    ok "[dry-run] 保留 3 个 CRD"
  fi
else
  for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
    if kubectl get crd "$crd" >/dev/null 2>&1; then
      run "kubectl delete crd $crd --ignore-not-found --timeout=60s"
    fi
  done
fi

# ============================================================
# 5/5 namespace
# ============================================================
log "[5/5] namespace"

if [ "$KEEP_NS" = "true" ]; then
  ok "--keep-ns:保留 ns $NAMESPACE"
elif kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  run "kubectl delete ns $NAMESPACE --timeout=60s"

  if [ "$APPLY" = "true" ] && kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    warn "ns 卡 Terminating,清 spec.finalizers"
    kubectl get ns "$NAMESPACE" -o json 2>/dev/null | \
      python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null | \
      kubectl replace --raw "/api/v1/namespaces/$NAMESPACE/finalize" -f - >/dev/null 2>&1 || true
    sleep 2
  fi

  if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
    [ "$APPLY" = "true" ] && ok "ns/$NAMESPACE 已删"
  else
    warn "ns/$NAMESPACE 仍在,见 k8s-cleanup-stuck skill"
  fi
fi

log "==== 完成 ===="

if [ "$APPLY" != "true" ]; then
  warn "以上是 DRY-RUN,确认后跑: bash $0 --apply"
fi
