#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — ArgoCD 健康度验证
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/argocd/test.sh
# 用法: bash test.sh [namespace]
#
# 不依赖外网 git。验证:
#   1) 6 个 Deployment + 1 个 StatefulSet 全 Ready
#   2) 3 个 argoproj.io CRD 注册
#   3) argocd-initial-admin-secret 可读(或已被改/删,给提示)
#   4) argocd-server Service 集群内 HTTPS 可达(自签 TLS,200/302/307)
#   5) (可选)argocd CLI 装了:打印版本

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0

NAMESPACE="${1:-argocd}"

log()    { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
pass()   { PASS=$((PASS+1)); echo -e "  ${GREEN}✓ PASS${NC} $*"; }
fail()   { FAIL=$((FAIL+1)); echo -e "  ${RED}✗ FAIL${NC} $*"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $*"; }
section(){ echo; echo -e "${BLUE}━━━ $* ━━━${NC}"; }

section "前置"

command -v kubectl >/dev/null || { fail "kubectl 不存在"; exit 1; }
pass "kubectl 可用"

if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  fail "ns/$NAMESPACE 不存在,先 bash install.sh"
  exit 1
fi
pass "ns/$NAMESPACE 存在"

section "1. 核心组件"

EXPECTED_DEPLOYS="argocd-server argocd-repo-server argocd-applicationset-controller argocd-notifications-controller argocd-dex-server argocd-redis"
for d in $EXPECTED_DEPLOYS; do
  if kubectl -n "$NAMESPACE" get deploy "$d" >/dev/null 2>&1; then
    READY=$(kubectl -n "$NAMESPACE" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    DESIRED=$(kubectl -n "$NAMESPACE" get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
    READY="${READY:-0}"; DESIRED="${DESIRED:-0}"
    if [ "$READY" -ge 1 ] && [ "$READY" = "$DESIRED" ]; then
      pass "$d ($READY/$DESIRED)"
    else
      fail "$d ($READY/$DESIRED)"
    fi
  else
    fail "$d Deployment 不存在"
  fi
done

if kubectl -n "$NAMESPACE" get sts argocd-application-controller >/dev/null 2>&1; then
  R=$(kubectl -n "$NAMESPACE" get sts argocd-application-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  D=$(kubectl -n "$NAMESPACE" get sts argocd-application-controller -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  R="${R:-0}"; D="${D:-0}"
  if [ "$R" -ge 1 ] && [ "$R" = "$D" ]; then
    pass "argocd-application-controller StatefulSet ($R/$D)"
  else
    fail "argocd-application-controller ($R/$D)"
  fi
else
  fail "argocd-application-controller StatefulSet 不存在"
fi

section "2. CRD"

for crd in applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    pass "CRD $crd"
  else
    fail "CRD $crd 缺失"
  fi
done

section "3. 初始密码 Secret"

if kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  PW=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  if [ -n "$PW" ]; then
    pass "argocd-initial-admin-secret 可读(初始密码长度=${#PW})"
    warn "  生产:登入改密码后立刻 kubectl -n $NAMESPACE delete secret argocd-initial-admin-secret"
  else
    fail "secret 存在但 password 字段为空"
  fi
else
  warn "argocd-initial-admin-secret 不存在 — 已被手动删(=安全做法)或装失败"
fi

section "4. argocd-server Service 可达"

SVC_TYPE=$(kubectl -n "$NAMESPACE" get svc argocd-server -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
if [ -z "$SVC_TYPE" ]; then
  fail "argocd-server Service 不存在"
else
  pass "argocd-server Service type=$SVC_TYPE"

  CIP=$(kubectl -n "$NAMESPACE" get svc argocd-server -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
  if [ -n "$CIP" ]; then
    log "  集群内 curl https://$CIP(临时 Pod,自签 TLS 用 -k)"
    PROBE_NAME="argocd-probe-$$"
    HTTP_CODE=$(kubectl -n "$NAMESPACE" run "$PROBE_NAME" \
        --image=curlimages/curl:latest --restart=Never --rm -i --quiet --timeout=60s \
        --command -- curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://$CIP" 2>/dev/null | tail -1 || echo "000")
    case "$HTTP_CODE" in
      200|302|307) pass "集群内 https://$CIP 应答 HTTP $HTTP_CODE" ;;
      *)           fail "集群内 https://$CIP 不通(HTTP $HTTP_CODE,查 argocd-server 日志)" ;;
    esac
  fi

  case "$SVC_TYPE" in
    NodePort)
      NP=$(kubectl -n "$NAMESPACE" get svc argocd-server -o jsonpath='{.spec.ports[?(@.port==443)].nodePort}' 2>/dev/null || true)
      NODE=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
      if [ -n "$NP" ] && [ -n "$NODE" ]; then
        CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$NODE:$NP" 2>/dev/null || echo "000")
        case "$CODE" in
          200|302|307) pass "NodePort https://$NODE:$NP 应答 HTTP $CODE" ;;
          *)           warn "NodePort https://$NODE:$NP 不通(HTTP $CODE,防火墙?)" ;;
        esac
      fi
      ;;
    LoadBalancer)
      LB=$(kubectl -n "$NAMESPACE" get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
      if [ -n "$LB" ]; then
        CODE=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://$LB" 2>/dev/null || echo "000")
        case "$CODE" in
          200|302|307) pass "LB IP https://$LB 应答 HTTP $CODE" ;;
          *)           warn "LB IP $LB 不通(HTTP $CODE,BGP/路由?)" ;;
        esac
      else
        warn "Service=LoadBalancer 但 EXTERNAL-IP <pending>"
      fi
      ;;
  esac
fi

section "5. argocd CLI(可选)"

if command -v argocd >/dev/null 2>&1; then
  CLI_VER=$(argocd version --client --short 2>/dev/null | head -1 || echo "?")
  pass "argocd CLI: $CLI_VER"
  warn "  手动验证: argocd login <地址> --username admin --insecure --grpc-web"
  warn "           argocd cluster list"
else
  warn "argocd CLI 未装,跳过(装法见 README)"
fi

section "总结"
TOTAL=$((PASS + FAIL))
echo -e "  通过: ${GREEN}$PASS${NC} / 失败: ${RED}$FAIL${NC} / 总计: $TOTAL"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}✓ 全部通过 — ArgoCD 健康${NC}"
else
  echo -e "  ${RED}✗ $FAIL 项失败,检查:${NC}"
  echo "    kubectl -n $NAMESPACE get pod"
  echo "    kubectl -n $NAMESPACE logs deploy/argocd-server --tail=50"
  echo "    kubectl -n $NAMESPACE logs sts/argocd-application-controller --tail=50"
fi
echo
exit $FAIL
