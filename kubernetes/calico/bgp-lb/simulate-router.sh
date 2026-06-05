#!/usr/bin/env bash
# 外部 BGP 路由器模拟 — 在任一台 Linux 机器上跑 FRRouting Docker,做 Calico 的 BGP peer
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/bgp-lb/simulate-router.sh
# 用法: bash simulate-router.sh [路由器 IP] [AS 号]
#
# 在集群 外 的一台 Linux 机器上跑(跟 K8s 节点同一二层网络即可)
# 如果是单机测试, 直接在某个 K8s 节点上跑也行(host network 绕过 K8s)

set -euo pipefail

ROUTER_IP="${1:-172.16.150.1}"       # 这台机器的 IP
ROUTER_AS="${2:-64501}"               # 路由器侧 AS
CALICO_AS="${CALICO_AS:-64500}"       # 集群侧 AS

# Calico 节点 IP(自动从 kubectl 拿, 或者手动填)
if command -v kubectl >/dev/null 2>&1 && kubectl cluster-info >/dev/null 2>&1; then
  NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
else
  # kubectl 不可用时手动指定 Calico 节点
  NODE_IPS="${NODE_IPS:-172.16.150.128 172.16.150.129 172.16.150.130}"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }

# ============================================================
# 生成 FRR 配置
# ============================================================
FRR_DIR="/tmp/frr-router"
rm -rf "$FRR_DIR"; mkdir -p "$FRR_DIR"

# daemons — 只开 bgpd
cat > "$FRR_DIR/daemons" <<EOF
bgpd=yes
ospfd=no
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
staticd=no
pbrd=no
bfdd=no
fabricd=no
EOF

# vtysh.conf
echo "service integrated-vtysh-config" > "$FRR_DIR/vtysh.conf"

# frr.conf — BGP 配置
cat > "$FRR_DIR/frr.conf" <<EOF
hostname fake-router
log stdout informational
!
router bgp ${ROUTER_AS}
 bgp router-id ${ROUTER_IP}
 no bgp ebgp-requires-policy
 !
EOF

for ip in $NODE_IPS; do
  cat >> "$FRR_DIR/frr.conf" <<EOF
 neighbor ${ip} remote-as ${CALICO_AS}
 neighbor ${ip} description calico-node
 !
EOF
done

cat >> "$FRR_DIR/frr.conf" <<EOF
 address-family ipv4 unicast
EOF

for ip in $NODE_IPS; do
  echo "  neighbor ${ip} activate" >> "$FRR_DIR/frr.conf"
done

cat >> "$FRR_DIR/frr.conf" <<EOF
 exit-address-family
!
line vty
!
EOF

log "FRR 配置生成: $FRR_DIR/frr.conf"
cat "$FRR_DIR/frr.conf"

# ============================================================
# 启动 FRR Docker(host 网络模式)
# ============================================================
log "启动 FRR Docker(AS=$ROUTER_AS, IP=$ROUTER_IP)..."

docker rm -f fake-router 2>/dev/null || true

docker run -d --name fake-router \
  --network host \
  --privileged \
  --cap-add NET_ADMIN \
  -v "$FRR_DIR/frr.conf:/etc/frr/frr.conf" \
  -v "$FRR_DIR/daemons:/etc/frr/daemons" \
  -v "$FRR_DIR/vtysh.conf:/etc/frr/vtysh.conf" \
  frrouting/frr:latest

log "等待 BGP session 建立(15s)..."
sleep 15

# ============================================================
# 验证
# ============================================================
echo
log "=== BGP Neighbors ==="
docker exec fake-router vtysh -c "show bgp summary"

echo
log "=== BGP Routes ==="
docker exec fake-router vtysh -c "show bgp ipv4 unicast" | head -20

echo
echo "========================================"
echo "  路由器模拟就绪"
echo "  AS=$ROUTER_AS  IP=$ROUTER_IP"
echo "========================================"
echo
echo "交互式配置:"
echo "  docker exec -it fake-router vtysh"
echo
echo "查看状态:"
echo "  docker exec fake-router vtysh -c 'show bgp summary'"
echo "  docker exec fake-router vtysh -c 'show bgp ipv4 unicast'"
echo
echo "停掉:"
echo "  docker rm -f fake-router"
