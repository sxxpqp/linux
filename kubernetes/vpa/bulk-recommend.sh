#!/usr/bin/env bash
# kubernetes/vpa/bulk-recommend.sh
# 批量给 Deployment 建 VPA(updateMode: Off)拿 requests 建议 / 一次性 dump / 清理
#
# 前置:
#   bash kubernetes/metrics-server/install.sh
#   bash kubernetes/vpa/install.sh
#
# 我建的 VPA 都打 label `vpa-source=bulk-recommend`,cleanup 只删自己的,不动手建的

set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

DEFAULT_EXCLUDE="kube-system,kube-public,kube-node-lease,tigera-operator,calico-system,calico-apiserver,metallb-system,ingress-nginx,goldilocks,cert-manager,vpa,velero"
LABEL_KEY="vpa-source"
LABEL_VAL="bulk-recommend"

NAMESPACE=""
ALL_NS="false"
EXCLUDE="$DEFAULT_EXCLUDE"
MODE="create"

usage() {
  cat <<EOF
用法: bash bulk-recommend.sh [模式] [ns 选择]

模式(三选一,默认 create):
  (默认)                给指定 ns 的所有 Deployment 建 VPA(updateMode: Off,打 label)
  --dump               打印所有 VPA 的 reco(Target / Lower / Upper bound,跨 ns)
  --cleanup            删本脚本建过的 VPA(只认 label ${LABEL_KEY}=${LABEL_VAL})

ns 选择(三种,默认当前 context 的 ns):
  --namespace=NS       只处理这个 ns
  --all-namespaces|-A  处理所有 ns(自动扣掉 --exclude 列表)
  --exclude=NS1,NS2    排除 ns,逗号分隔
                       默认: $DEFAULT_EXCLUDE

  -h, --help           显示帮助

示例:
  # 全集群建,排除基础设施(等 10 分钟拿建议)
  bash bulk-recommend.sh -A

  # 只在 biz ns 建
  bash bulk-recommend.sh --namespace=biz

  # 全集群 dump 所有 VPA 建议(对齐表格)
  bash bulk-recommend.sh -A --dump

  # 全集群清理本脚本建的 VPA
  bash bulk-recommend.sh -A --cleanup
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace=*) NAMESPACE="${1#*=}" ;;
    --all-namespaces|-A) ALL_NS="true" ;;
    --exclude=*) EXCLUDE="${1#*=}" ;;
    --dump) MODE="dump" ;;
    --cleanup) MODE="cleanup" ;;
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

# 前置检查
command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
kubectl get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null 2>&1 \
  || { err "VPA CRD 没装,先 bash kubernetes/vpa/install.sh"; exit 1; }

# 算 namespace 列表
build_ns_list() {
  if [ "$ALL_NS" = "true" ]; then
    local ex_pat="^($(echo "$EXCLUDE" | tr ',' '|'))$"
    kubectl get ns -o jsonpath='{.items[*].metadata.name}' \
      | tr ' ' '\n' | grep -vE "$ex_pat" | grep -v '^$'
  elif [ -n "$NAMESPACE" ]; then
    echo "$NAMESPACE"
  else
    local cur
    cur=$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)
    echo "${cur:-default}"
  fi
}

NS_LIST=$(build_ns_list)
[ -z "$NS_LIST" ] && { err "没有匹配的 namespace,检查 --namespace / --exclude / -A"; exit 1; }
NS_COUNT=$(echo "$NS_LIST" | wc -l | tr -d ' ')

log "模式: $MODE | namespace($NS_COUNT 个):"
echo "$NS_LIST" | sed 's/^/    /'
echo

# ============================================================
case "$MODE" in
# ============================================================

create)
  total=0; created=0; skipped=0
  for ns in $NS_LIST; do
    deploys=$(kubectl -n "$ns" get deploy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    [ -z "$deploys" ] && continue
    for d in $deploys; do
      total=$((total+1))
      vpa_name="vpa-$d"
      # 名字超长截断(K8s 资源名 ≤ 253 字符,这里防御性)
      [ ${#vpa_name} -gt 253 ] && vpa_name="vpa-$(echo -n "$d" | sha256sum | cut -c1-12)"
      if kubectl -n "$ns" get vpa "$vpa_name" >/dev/null 2>&1; then
        skipped=$((skipped+1))
        continue
      fi
      cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: $vpa_name
  namespace: $ns
  labels:
    $LABEL_KEY: $LABEL_VAL
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $d
  updatePolicy:
    updateMode: "Off"
YAML
      created=$((created+1))
      ok "$ns/$d → vpa/$vpa_name"
    done
  done
  echo
  log "完成: 扫了 $total 个 Deployment,新建 $created,已存在跳过 $skipped"
  echo
  log "下一步:"
  echo "  - 等 5-15 分钟(recommender 第一轮采样)"
  echo "  - 看建议: bash $0 ${ALL_NS:+-A }${NAMESPACE:+--namespace=$NAMESPACE }--dump"
  echo "  - 不要了: bash $0 ${ALL_NS:+-A }${NAMESPACE:+--namespace=$NAMESPACE }--cleanup"
  ;;

# ============================================================
dump)
  no_reco=0; with_reco=0
  TMPFILE=$(mktemp /tmp/vpa-dump.XXXXXX)
  trap "rm -f $TMPFILE" EXIT
  {
    printf "VPA\tCONTAINER\tTARGET_CPU\tTARGET_MEM\tLOWER_CPU\tLOWER_MEM\tUPPER_CPU\tUPPER_MEM\n"
    for ns in $NS_LIST; do
      vpas=$(kubectl -n "$ns" get vpa -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
      [ -z "$vpas" ] && continue
      for v in $vpas; do
        # 一次性拿这个 VPA 的全部容器 reco
        line=$(kubectl -n "$ns" get vpa "$v" \
          -o jsonpath='{range .status.recommendation.containerRecommendations[*]}'"$ns/$v"'{"\t"}{.containerName}{"\t"}{.target.cpu}{"\t"}{.target.memory}{"\t"}{.lowerBound.cpu}{"\t"}{.lowerBound.memory}{"\t"}{.upperBound.cpu}{"\t"}{.upperBound.memory}{"\n"}{end}' 2>/dev/null || true)
        if [ -z "$line" ]; then
          no_reco=$((no_reco+1))
        else
          echo "$line"
          with_reco=$((with_reco+1))
        fi
      done
    done
  } > "$TMPFILE"

  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t' "$TMPFILE"
  else
    cat "$TMPFILE"
  fi
  echo
  log "汇总: $with_reco 个 VPA 已出建议,$no_reco 个还没有(等下一轮采样,或 metrics-server 没接通)"
  ;;

# ============================================================
cleanup)
  total=0
  for ns in $NS_LIST; do
    names=$(kubectl -n "$ns" get vpa -l "$LABEL_KEY=$LABEL_VAL" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    [ -z "$names" ] && continue
    for n in $names; do
      kubectl -n "$ns" delete vpa "$n" --wait=false >/dev/null
      total=$((total+1))
      ok "deleted $ns/$n"
    done
  done
  echo
  log "删除 $total 个本脚本建的 VPA(label $LABEL_KEY=$LABEL_VAL)"
  ;;

esac
