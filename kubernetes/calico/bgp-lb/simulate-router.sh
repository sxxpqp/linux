#!/usr/bin/env bash
# 模拟上游 BGP 路由器 — 在集群里跑一个 bird 容器跟 Calico 节点建 peer
# 用法: bash simulate-router.sh
#
# 拉一个 netshoot 镜像跑 bird, 模拟路由器 AS 64501 跟 Calico 节点(AS 64500) peer
# 不需要真实路由器, 在集群内就能验证 BGP 路由交换

set -euo pipefail

ROUTER_AS="${ROUTER_AS:-64501}"
CALICO_AS="${CALICO_AS:-64500}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }

# 拿所有节点 IP
NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
CONTROL_NODE=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# 生成 bird.conf
BIRD_CONF="/tmp/bird-sim.conf"
cat > "$BIRD_CONF" <<EOF
router id ${CONTROL_NODE};
protocol device { scan time 10; }
protocol kernel { export all; }
EOF

for ip in $NODE_IPS; do
  cat >> "$BIRD_CONF" <<EOF
protocol bgp node_${ip##*.} {
  local as ${ROUTER_AS};
  neighbor ${ip} as ${CALICO_AS};
  import all;
  export all;
}
EOF
done

log "bird.conf 生成: $BIRD_CONF"
cat "$BIRD_CONF"

# 创建模拟路由器 Pod
kubectl delete pod fake-router --ignore-not-found --force 2>/dev/null || true

log "创建 fake-router Pod(bird 模拟 AS $ROUTER_AS)..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: fake-router
  namespace: default
spec:
  hostNetwork: true
  nodeName: kh
  containers:
  - name: bird
    image: nicolaka/netshoot:latest
    command:
    - /bin/sh
    - -c
    - |
      apk add --no-cache bird
      bird -c /etc/bird-sim.conf -d &
      sleep 8
      echo "=== BGP Neighbors ==="
      birdc show protocols
      echo "=== BGP Routes (from Calico) ==="
      birdc show route | head -20
      echo "=== 路由器就绪,查看路由: birdc show route ==="
      tail -f /dev/null
    volumeMounts:
    - name: bird-conf
      mountPath: /etc/bird-sim.conf
      subPath: bird.conf
    securityContext:
      capabilities:
        add: ["NET_ADMIN", "NET_RAW"]
  volumes:
  - name: bird-conf
    configMap:
      name: fake-router-bird-conf
  restartPolicy: Never
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fake-router-bird-conf
  namespace: default
data:
  bird.conf: |
$(sed 's/^/    /' "$BIRD_CONF")
EOF

log "等待 bird 启动(30s)..."
sleep 30
echo
log "=== BGP 邻居状态 ==="
kubectl logs fake-router 2>/dev/null | head -30

echo
echo "================================================"
echo " fake-router 就绪后手动验证:"
echo "  kubectl logs fake-router"
echo "  kubectl exec fake-router -- birdc show protocols"
echo "  kubectl exec fake-router -- birdc show route"
echo ""
echo " 清理: kubectl delete pod fake-router --force"
echo "       kubectl delete cm fake-router-bird-conf"
echo "================================================"
