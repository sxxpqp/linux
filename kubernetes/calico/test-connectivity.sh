#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — Calico CNI 连通性验证
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/test-connectivity.sh
# 用法: curl -sL <URL> | bash
#
# 验证 Calico 网络的:
#   1. 组件健康(calico-node / calico-kube-controllers / calico-typha)
#   2. Pod ↔ Pod (同节点)
#   3. Pod ↔ Pod (跨节点)
#   4. Pod → ClusterIP Service
#   5. Pod → 外部网络(egress)
#   6. DNS 解析(coredns)
#   7. NodePort / LoadBalancer(如有)
# 测试完成后自动清理临时资源。

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0
TEST_NS="calico-conn-test-$(date +%s)"

log()    { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
pass()   { PASS=$((PASS+1)); echo -e "  ${GREEN}✓ PASS${NC} $*"; }
fail()   { FAIL=$((FAIL+1)); echo -e "  ${RED}✗ FAIL${NC} $*"; }
warn()   { echo -e "  ${YELLOW}⚠${NC} $*"; }
section(){ echo; echo -e "${BLUE}━━━ $* ━━━${NC}"; }

cleanup() {
  echo
  log "清理测试资源..."
  kubectl delete ns "$TEST_NS" --ignore-not-found --timeout=30s >/dev/null 2>&1 || true
  # 清理可能残留的 ClusterRoleBinding(如果用了 hostNetwork 测试)
  kubectl delete clusterrolebinding calico-conn-test --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ============================================================
# 前置检查
# ============================================================
section "前置检查"

command -v kubectl >/dev/null || { fail "kubectl 不存在"; exit 1; }
pass "kubectl 可用"

kubectl cluster-info --request-timeout=5s >/dev/null 2>&1 || { fail "集群不可达"; exit 1; }
pass "集群可达"

# 检测 Calico 是否在跑
CALICO_NS=""
if kubectl get ns calico-system >/dev/null 2>&1; then
  CALICO_NS="calico-system"
elif kubectl -n kube-system get ds calico-node >/dev/null 2>&1; then
  CALICO_NS="kube-system"
else
  fail "未找到 Calico(namespace 既没有 calico-system 也没有 kube-system/calico-node)"
  warn "  → 确认 Calico 已安装: kubectl get pods -A | grep calico"
  exit 1
fi
pass "Calico namespace: $CALICO_NS"

# 节点数(至少 2 个才能测跨节点通信)
NODE_COUNT=$(kubectl get nodes -o name --no-headers 2>/dev/null | wc -l)
log "集群节点数: $NODE_COUNT"
if [ "$NODE_COUNT" -ge 2 ]; then
  pass "节点数 ≥ 2,可测跨节点通信"
else
  warn "只有 $NODE_COUNT 个节点,跳过跨节点测试"
fi

# ============================================================
# 1. Calico 组件健康检查
# ============================================================
section "1. Calico 组件健康"

# calico-node
NOT_READY=$(kubectl -n "$CALICO_NS" get pods -l k8s-app=calico-node --no-headers 2>/dev/null | grep -vc 'Running' || true)
if [ "$NOT_READY" -eq 0 ]; then
  pass "calico-node 全部 Running"
else
  fail "calico-node $NOT_READY 个未 Running"
  kubectl -n "$CALICO_NS" get pods -l k8s-app=calico-node --no-headers 2>/dev/null | grep -v Running || true
fi

# calico-kube-controllers
CTRL_READY=$(kubectl -n "$CALICO_NS" get deploy calico-kube-controllers -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "${CTRL_READY:-0}" -ge 1 ]; then
  pass "calico-kube-controllers ready: $CTRL_READY"
else
  fail "calico-kube-controllers 未 ready"
fi

# calico-typha(如果有)
if kubectl -n "$CALICO_NS" get deploy calico-typha >/dev/null 2>&1; then
  TYPHA_READY=$(kubectl -n "$CALICO_NS" get deploy calico-typha -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${TYPHA_READY:-0}" -ge 1 ]; then
    pass "calico-typha ready: $TYPHA_READY"
  else
    fail "calico-typha 未 ready"
  fi
else
  warn "calico-typha 未部署(小集群可选)"
fi

# BGP / IPPool
if kubectl get ippools >/dev/null 2>&1; then
  IPPOOL_COUNT=$(kubectl get ippools -o name --no-headers 2>/dev/null | wc -l)
  pass "IPPool 数量: $IPPOOL_COUNT"
else
  warn "无法查询 IPPool(可能没有 calicoctl,或用的不是 BGP 模式)"
fi

# FelixConfiguration(operator 模式不一定会显式创建)
if kubectl get felixconfigurations default >/dev/null 2>&1; then
  pass "FelixConfiguration default 存在"
fi

# ============================================================
# 2. 部署测试 Pod
# ============================================================
section "2. 部署测试 Pod"

log "创建测试 namespace: $TEST_NS"
kubectl create ns "$TEST_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# 每个 worker 节点跑一个 nginx(用 hostNetwork=false 测 Pod 网络)
# 优先排到不同节点
log "部署 nginx(每节点一个,anti-affinity 分散)..."
kubectl -n "$TEST_NS" apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: test-nginx
  namespace: $TEST_NS
spec:
  selector:
    matchLabels:
      app: test-nginx
  template:
    metadata:
      labels:
        app: test-nginx
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role.kubernetes.io/control-plane
                    operator: DoesNotExist
                  - key: node-role.kubernetes.io/master
                    operator: DoesNotExist
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          readinessProbe:
            tcpSocket:
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: test-nginx-svc
  namespace: $TEST_NS
spec:
  selector:
    app: test-nginx
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
EOF

log "等待 nginx Pod 全部 ready(最多 60s)..."
if ! kubectl -n "$TEST_NS" rollout status ds/test-nginx --timeout=60s; then
  fail "nginx DaemonSet 未就绪"
  kubectl -n "$TEST_NS" get pods -l app=test-nginx
  exit 1
fi
pass "nginx DaemonSet ready"

# 获取 Pod IP 列表(按节点分组)
log "收集 Pod IP(按节点分组)..."
NGINX_PODS=$(kubectl -n "$TEST_NS" get pods -l app=test-nginx -o json)
NGINX_COUNT=$(echo "$NGINX_PODS" | jq '.items | length')
log "nginx Pod 数: $NGINX_COUNT"
echo "$NGINX_PODS" | jq -r '.items[] | "  \(.spec.nodeName) → \(.status.podIP)  [\(.metadata.name)]"'

# 取不同节点的两个 Pod(用于跨节点测试)
POD1_NAME=$(echo "$NGINX_PODS" | jq -r '.items[0].metadata.name')
POD1_IP=$(echo "$NGINX_PODS" | jq -r '.items[0].status.podIP')
POD1_NODE=$(echo "$NGINX_PODS" | jq -r '.items[0].spec.nodeName')

POD2_NAME=""; POD2_IP=""; POD2_NODE=""
for i in $(seq 1 $((NGINX_COUNT - 1))); do
  _n=$(echo "$NGINX_PODS" | jq -r ".items[$i].spec.nodeName")
  if [ "$_n" != "$POD1_NODE" ]; then
    POD2_NAME=$(echo "$NGINX_PODS" | jq -r ".items[$i].metadata.name")
    POD2_IP=$(echo "$NGINX_PODS" | jq -r ".items[$i].status.podIP")
    POD2_NODE="$_n"
    break
  fi
done

# 启动一个 busybox 测试客户端(kube-proxy 删了也不影响 Pod 网络)
log "部署 busybox 测试客户端..."
kubectl -n "$TEST_NS" run test-busybox --image=busybox:stable --restart=Never -- sleep 600 >/dev/null 2>&1 || true
kubectl -n "$TEST_NS" wait --for=condition=Ready pod/test-busybox --timeout=60s
BUSYBOX_IP=$(kubectl -n "$TEST_NS" get pod test-busybox -o jsonpath='{.status.podIP}')
BUSYBOX_NODE=$(kubectl -n "$TEST_NS" get pod test-busybox -o jsonpath='{.spec.nodeName}')
pass "busybox ready($BUSYBOX_NODE, $BUSYBOX_IP)"

# Felix attach BPF 程序到新 Pod 的 cali* 接口需要几秒,
# 立刻测会踩 "Operation not permitted"(BPF 程序还没加载完)。
# 等 Felix 的 reconciliation loop 跑完再开始测。
log "等待 Calico BPF 程序 attach(10s)..."
sleep 10
ok "预热完成,开始连通性测试"

# kubectl exec 包装(集中处理超时)
exec_in_busybox() {
  local desc="$1"; shift
  local out
  if out=$(kubectl -n "$TEST_NS" exec test-busybox --timeout=10s -- "$@" 2>&1); then
    return 0
  else
    echo "$out"
    return 1
  fi
}

# ============================================================
# 3. Pod ↔ Pod(同节点)
# ============================================================
section "3. Pod ↔ Pod (同节点)"

# busybox → 同节点的 nginx
SAME_NODE_TARGET=""
for i in $(seq 0 $((NGINX_COUNT - 1))); do
  _node=$(echo "$NGINX_PODS" | jq -r ".items[$i].spec.nodeName")
  if [ "$_node" = "$BUSYBOX_NODE" ]; then
    SAME_NODE_TARGET=$(echo "$NGINX_PODS" | jq -r ".items[$i].status.podIP")
    break
  fi
done

if [ -n "$SAME_NODE_TARGET" ]; then
  log "busybox($BUSYBOX_NODE) → nginx($BUSYBOX_NODE 同节点) $SAME_NODE_TARGET:80"
  if exec_in_busybox "同节点 Pod→Pod" wget -qO- --timeout=5 "http://$SAME_NODE_TARGET" | grep -qE 'nginx|Welcome'; then
    pass "同节点 Pod→Pod 连通,nginx 响应正常"
  else
    fail "同节点 Pod→Pod 不通或 nginx 无响应"
  fi
else
  warn "busybox 所在节点无 nginx,跳过同节点测试"
fi

# ============================================================
# 4. Pod ↔ Pod(跨节点)
# ============================================================
section "4. Pod ↔ Pod (跨节点)"

if [ -n "$POD2_IP" ] && [ "$NODE_COUNT" -ge 2 ]; then
  log "busybox($BUSYBOX_NODE) → nginx($POD2_NODE) $POD2_IP:80"
  if exec_in_busybox "跨节点 Pod→Pod" wget -qO- --timeout=5 "http://$POD2_IP" | grep -qE 'nginx|Welcome'; then
    pass "跨节点 Pod→Pod 连通 ($BUSYBOX_NODE → $POD2_NODE)"
  else
    fail "跨节点 Pod→Pod 不通 ($BUSYBOX_NODE → $POD2_NODE)"
  fi
elif [ -n "$POD1_IP" ]; then
  # 单节点:至少测一下到另一个 nginx Pod
  log "busybox($BUSYBOX_NODE) → nginx $POD1_IP:80(单节点)"
  if exec_in_busybox "单节点 Pod→Pod" wget -qO- --timeout=5 "http://$POD1_IP" | grep -qE 'nginx|Welcome'; then
    pass "Pod→Pod 连通(单节点)"
  else
    fail "Pod→Pod 不通"
  fi
fi

# ============================================================
# 5. Pod → ClusterIP Service
# ============================================================
section "5. Pod → ClusterIP Service"

SVC_IP=$(kubectl -n "$TEST_NS" get svc test-nginx-svc -o jsonpath='{.spec.clusterIP}')
log "busybox → ClusterIP $SVC_IP:80"
if exec_in_busybox "ClusterIP" wget -qO- --timeout=5 "http://$SVC_IP" | grep -qE 'nginx|Welcome'; then
  pass "Pod→ClusterIP 连通 ($SVC_IP)"
else
  fail "Pod→ClusterIP 不通 ($SVC_IP)"
  warn "  → 可能原因: kube-proxy 模式/service 转发/Calico eBPF kube-proxy replacement"
  warn "  → 手动验证: kubectl -n $TEST_NS exec test-busybox -- wget -qO- http://$SVC_IP"
fi

# ============================================================
# 6. DNS 解析
# ============================================================
section "6. DNS 解析"

# 查 coredns 是否在跑
if kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -q Running; then
  pass "CoreDNS Pod Running"
else
  warn "CoreDNS 未检测到 Running 状态"
fi

log "busybox → DNS 解析 kubernetes.default.svc.cluster.local"
if exec_in_busybox "DNS" nslookup kubernetes.default.svc.cluster.local 2>&1 | grep -qE 'Address|addr'; then
  pass "DNS 解析正常"
else
  fail "DNS 解析失败"
  warn "  → 手动验证: kubectl -n $TEST_NS exec test-busybox -- nslookup kubernetes.default"
fi

# 解析我们自己的 service
log "busybox → DNS 解析 test-nginx-svc.$TEST_NS.svc.cluster.local"
if exec_in_busybox "DNS(service)" nslookup "test-nginx-svc.$TEST_NS.svc.cluster.local" 2>&1 | grep -q "$SVC_IP"; then
  pass "Service DNS 解析正确($SVC_IP)"
else
  fail "Service DNS 解析失败或 IP 不匹配"
fi

# ============================================================
# 7. Pod → 外部网络(egress)
# ============================================================
section "7. Pod → 外部网络"

# 测试 HTTPS 出站(用多个目标,避免单点故障误判)
log "busybox → 外网 HTTP(wget)"
# busybox wget 不支持 TLS,用 HTTP 目标(baidu / httpbin 都稳)
EGRESS_OK=false
for target in \
  "http://www.baidu.com" \
  "http://httpbin.org/get"; do
  if exec_in_busybox "egress-${target##*/}" wget -qO- --timeout=8 "$target" >/dev/null 2>&1; then
    pass "Pod→外网连通 ($target)"
    EGRESS_OK=true
    break
  fi
done
if [ "$EGRESS_OK" != "true" ]; then
  fail "Pod→外网 HTTP 均不通"
  warn "  → 检查: NAT 出站 / 防火墙 / 代理配置"
fi

# DNS 外网解析
log "busybox → 外网 DNS(baidu.com)"
if exec_in_busybox "egress-dns" nslookup baidu.com 2>&1 | grep -qE 'Address.*[0-9]+\.[0-9]+'; then
  pass "外网 DNS 解析正常"
else
  fail "外网 DNS 解析失败"
fi

# ============================================================
# 8. NodePort(可选)
# ============================================================
section "8. NodePort(可选)"

kubectl -n "$TEST_NS" delete svc test-nginx-nodeport --ignore-not-found --wait 2>/dev/null || true
kubectl -n "$TEST_NS" expose ds test-nginx --name=test-nginx-nodeport --type=NodePort --port=80 >/dev/null 2>&1 || true
sleep 2  # 等 Service 分配 NodePort
NODEPORT=$(kubectl -n "$TEST_NS" get svc test-nginx-nodeport -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)
if [ -n "$NODEPORT" ]; then
  # 取一个 worker 节点 IP
  NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  log "测试 NodePort $NODE_IP:$NODEPORT (从 busybox)..."
  if exec_in_busybox "NodePort" wget -qO- --timeout=5 "http://$NODE_IP:$NODEPORT" | grep -qE 'nginx|Welcome'; then
    pass "NodePort 连通 ($NODE_IP:$NODEPORT)"
  else
    fail "NodePort 不通 ($NODE_IP:$NODEPORT)"
    warn "  → 手动验证: curl -s http://$NODE_IP:$NODEPORT | head"
  fi
else
  warn "跳过 NodePort 测试(无法获取 nodePort)"
fi

# ============================================================
# 总结
# ============================================================
section "测试总结"

TOTAL=$((PASS + FAIL))
echo -e "  通过: ${GREEN}$PASS${NC} / 失败: ${RED}$FAIL${NC} / 总计: $TOTAL"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}✓ 全部通过 — Calico 网络正常${NC}"
else
  echo -e "  ${RED}✗ $FAIL 项失败,Calico 网络可能有问题${NC}"
fi
echo

# ============================================================
# 附加诊断(失败时有用)
# ============================================================
if [ "$FAIL" -gt 0 ]; then
  section "诊断信息(失败时自动输出)"

  echo "--- Calico Pods ---"
  kubectl -n "$CALICO_NS" get pods -o wide 2>&1 || true

  echo
  echo "--- calico-node 日志(最后 20 行,取第一个 Pod) ---"
  FIRST_NODE=$(kubectl -n "$CALICO_NS" get pods -l k8s-app=calico-node -o name 2>/dev/null | head -1)
  if [ -n "$FIRST_NODE" ]; then
    kubectl -n "$CALICO_NS" logs "$FIRST_NODE" --tail=20 2>&1 || true
  fi

  echo
  echo "--- IPPools ---"
  kubectl get ippools -o yaml 2>&1 || true

  echo
  echo "--- FelixConfiguration ---"
  kubectl get felixconfigurations default -o yaml 2>&1 | head -30 || true

  echo
  echo "--- 测试 Pod 状态(清理前) ---"
  kubectl -n "$TEST_NS" get pods -o wide 2>&1 || true
  kubectl -n "$TEST_NS" get svc 2>&1 || true
fi

# cleanup 在 trap 里自动执行
exit $FAIL
