#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — ingress-nginx 连通性验证
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/ingress/test.sh
# 用法: bash test.sh [ingress-node-ip]
#
# 部署测试应用 + Ingress 规则, 从集群内 Pod 和集群外分别验证 ingress-nginx 是否正常转发。

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0
TEST_NS="ingress-test-$(date +%s)"

log()    { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
pass()   { PASS=$((PASS+1)); echo -e "  ${GREEN}✓ PASS${NC} $*"; }
fail()   { FAIL=$((FAIL+1)); echo -e "  ${RED}✗ FAIL${NC} $*"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $*"; }
section(){ echo; echo -e "${BLUE}━━━ $* ━━━${NC}"; }

cleanup() {
  log "清理测试资源..."
  kubectl delete ns "$TEST_NS" --ignore-not-found --timeout=30s >/dev/null 2>&1 || true
}
trap cleanup EXIT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# ingress 节点 IP(优先用参数,否则自动取第一个 ingress controller Pod 所在节点)
INGRESS_NODE="${1:-}"
if [ -z "$INGRESS_NODE" ]; then
  INGRESS_NODE=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller \
    -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null || true)
fi

section "前置检查"

command -v kubectl >/dev/null || { fail "kubectl 不存在"; exit 1; }
pass "kubectl 可用"

if ! kubectl get ns ingress-nginx >/dev/null 2>&1; then
  fail "ingress-nginx namespace 不存在,请先安装: bash install.sh --label-nodes=<NODE>"
  exit 1
fi
pass "ingress-nginx namespace 存在"

READY=$(kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller --no-headers 2>/dev/null | grep -c Running || true)
if [ "$READY" -ge 1 ]; then
  pass "ingress-nginx controller Running: $READY 个"
else
  fail "ingress-nginx controller 未 Running"
  exit 1
fi

section "部署测试应用"

log "创建测试 namespace: $TEST_NS"
kubectl create ns "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 部署 nginx + Service + Ingress
kubectl -n "$TEST_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: hello
spec:
  selector:
    app: hello
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
spec:
  ingressClassName: nginx
  rules:
    - host: hello.ingress.test
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: hello
                port:
                  number: 80
EOF

log "等待 hello Pod ready..."
kubectl -n "$TEST_NS" wait --for=condition=Available deploy/hello --timeout=120s
HELLO_IP=$(kubectl -n "$TEST_NS" get pod -l app=hello -o jsonpath='{.items[0].status.podIP}')
pass "hello Pod ready($HELLO_IP)"

log "部署测试客户端 busybox..."
kubectl -n "$TEST_NS" run client --image=busybox:stable --restart=Never -- sleep 300 >/dev/null 2>&1 || true
kubectl -n "$TEST_NS" wait --for=condition=Ready pod/client --timeout=180s
pass "client ready"

section "1. Pod → Service ClusterIP"

SVC_IP=$(kubectl -n "$TEST_NS" get svc hello -o jsonpath='{.spec.clusterIP}')
log "client → hello Service($SVC_IP):80"
if kubectl -n "$TEST_NS" exec client -- wget -qO- --timeout=5 "http://$SVC_IP" 2>&1 | grep -qE 'nginx|Welcome'; then
  pass "Pod→ClusterIP 连通"
else
  fail "Pod→ClusterIP 不通"
fi

section "2. Pod → Ingress(集群内)"

# 从集群内 Pod 通过 ingress-nginx controller Service 访问
INGRESS_SVC_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -n "$INGRESS_SVC_IP" ]; then
  log "client → ingress Service($INGRESS_SVC_IP):80 (Host: hello.ingress.test)"
  if kubectl -n "$TEST_NS" exec client -- wget -qO- --timeout=5 --header='Host: hello.ingress.test' "http://$INGRESS_SVC_IP" 2>&1 | grep -qE 'nginx|Welcome'; then
    pass "集群内 Ingress 转发正常"
  else
    fail "集群内 Ingress 转发失败"
  fi
else
  warn "无 ingress-nginx-controller ClusterIP,跳过集群内测试"
fi

section "3. 外部 → Ingress(节点 80 端口)"

if [ -z "$INGRESS_NODE" ]; then
  warn "未指定 ingress 节点 IP,跳过外部测试"
else
  log "curl -H 'Host: hello.ingress.test' http://$INGRESS_NODE:80"
  HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: hello.ingress.test' --max-time 5 "http://$INGRESS_NODE:80" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    pass "外部 Ingress 转发正常($INGRESS_NODE:80 → 200)"
  elif [ "$HTTP_CODE" = "404" ]; then
    fail "Ingress 未命中(404), 检查 Ingress 规则或 controller 日志"
  else
    fail "外部 Ingress 不可达(HTTP $HTTP_CODE)"
  fi
fi

section "测试总结"

TOTAL=$((PASS + FAIL))
echo -e "  通过: ${GREEN}$PASS${NC} / 失败: ${RED}$FAIL${NC} / 总计: $TOTAL"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}✓ 全部通过 — ingress-nginx 正常${NC}"
else
  echo -e "  ${RED}✗ $FAIL 项失败,检查:"
  echo "    kubectl -n ingress-nginx logs ds/ingress-nginx-controller --tail=50"
  echo "    kubectl -n $TEST_NS describe ingress hello"
fi
echo

exit $FAIL
