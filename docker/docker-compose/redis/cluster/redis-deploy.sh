#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/docker-compose/redis/cluster/redis-deploy.sh
# ================================================================
# Redis Cluster 3主3从 三节点生产部署脚本
# 镜像: registry.cn-hangzhou.aliyuncs.com/sxxpqp/redis:7.x
#
# 集群架构（主从跨机器，容错最优）:
#   Node1: redis-master-1(:6379) + redis-slave-2(:6380)
#   Node2: redis-master-2(:6379) + redis-slave-3(:6380)
#   Node3: redis-master-3(:6379) + redis-slave-1(:6380)
#
# 用法: bash deploy_redis.sh
# 参数缓存到 .deploy_redis_state，下次运行自动跳过
# ================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
title()   { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"
            echo -e "${BOLD}${BLUE}  $*${NC}"
            echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}\n"; }

STATE_FILE="$(cd "$(dirname "$0")" && pwd)/.deploy_redis_state"

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    echo -e "${CYAN}[INFO]${NC}  检测到状态文件: ${STATE_FILE}"
    echo -e "${CYAN}[INFO]${NC}  已缓存的参数将自动跳过输入\n"
  fi
}

save_state() {
  cat > "$STATE_FILE" << STATEOF
# Redis 集群部署状态 — 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
REDIS_VERSION=${REDIS_VERSION:-}
DATA_DIR=${DATA_DIR:-}
DEPLOY_DIR=${DEPLOY_DIR:-}
NODE1_IP=${NODE1_IP:-}
NODE2_IP=${NODE2_IP:-}
NODE3_IP=${NODE3_IP:-}
NODE_ID=${NODE_ID:-}
CURRENT_IP=${CURRENT_IP:-}
REDIS_PASSWORD=${REDIS_PASSWORD:-}
STATEOF
  chmod 600 "$STATE_FILE"
}

ask() {
  local var="$1" prompt="$2" default="${3:-}"
  local cur="${!var:-}"
  if [[ -n "$cur" ]]; then
    echo -e "  ${GREEN}✓ (缓存)${NC} ${prompt}: ${BOLD}${cur}${NC}"; return
  fi
  local input
  if [[ -n "$default" ]]; then
    read -rp "  ${prompt} [默认: ${default}]: " input
    printf -v "$var" '%s' "${input:-$default}"
  else
    while [[ -z "${input:-}" ]]; do
      read -rp "  ${prompt}: " input
      [[ -z "$input" ]] && warn "不能为空，请重新输入"
    done
    printf -v "$var" '%s' "$input"
  fi
}

ask_password() {
  local var="$1" prompt="$2"
  local cur="${!var:-}"
  if [[ -n "$cur" ]]; then
    echo -e "  ${GREEN}✓ (缓存)${NC} ${prompt}: ${BOLD}********${NC}"; return
  fi
  local input confirm
  while true; do
    read -rsp "  ${prompt}: " input; echo
    read -rsp "  确认 ${prompt}: " confirm; echo
    [[ "$input" == "$confirm" ]] && break
    warn "两次输入不一致，请重新输入"
  done
  printf -v "$var" '%s' "$input"
}

validate_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "IP 格式不正确: $1"
}

wait_healthy() {
  local name="$1" max="${2:-24}"
  for i in $(seq 1 $max); do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "starting")
    if [[ "$STATUS" == "healthy" ]]; then success "$name ✓"; return 0; fi
    printf "  [%2d/%d] %-30s 状态: %-12s\r" "$i" "$max" "$name" "$STATUS"
    sleep 5
  done
  echo ""
  warn "$name 未能在时限内 healthy，请检查: docker logs $name"
}

# ================================================================
# Banner
# ================================================================
clear
echo -e "${BOLD}${GREEN}"
cat << 'BANNER'
  _____          _ _      
 |  __ \        | (_)     
 | |__) |___  __| |_ ___  
 |  _  // _ \/ _` | / __| 
 | | \ \  __/ (_| | \__ \ 
 |_|  \_\___|\__,_|_|___/ 

      Cluster 3主3从 — 三节点生产部署向导
      Node1: redis-master-1(6379) + redis-slave-2(6380)
      Node2: redis-master-2(6379) + redis-slave-3(6380)
      Node3: redis-master-3(6379) + redis-slave-1(6380)
BANNER
echo -e "${NC}"

load_state

# ================================================================
# 一、收集参数
# ================================================================
title "Step 1 / 4  参数配置"

if [[ -n "${REDIS_VERSION:-}" ]]; then
  echo -e "  ${GREEN}✓ (缓存)${NC} Redis 版本: ${BOLD}${REDIS_VERSION}${NC}"
else
  echo "    1) 7.4  (最新稳定)"
  echo "    2) 7.2  (LTS)"
  echo "    3) 自定义"
  read -rp "  请选择 [默认: 1]: " _ver
  case "${_ver:-1}" in
    1) REDIS_VERSION="7.4" ;;
    2) REDIS_VERSION="7.2" ;;
    3) read -rp "  版本号: " REDIS_VERSION ;;
    *) REDIS_VERSION="7.4" ;;
  esac
fi

echo ""
ask DATA_DIR   "数据根目录"    "/data/redis"
ask DEPLOY_DIR "部署配置目录"  "/opt/redis-cluster"

echo ""
info "三台服务器 IP："
ask NODE1_IP "  Node1 IP"
ask NODE2_IP "  Node2 IP"
ask NODE3_IP "  Node3 IP"
validate_ip "$NODE1_IP"; validate_ip "$NODE2_IP"; validate_ip "$NODE3_IP"

echo ""
if [[ -n "${NODE_ID:-}" ]]; then
  echo -e "  ${GREEN}✓ (缓存)${NC} 当前节点: ${BOLD}Node${NODE_ID} (${CURRENT_IP})${NC}"
else
  echo "    1) Node1 — ${NODE1_IP}"
  echo "    2) Node2 — ${NODE2_IP}"
  echo "    3) Node3 — ${NODE3_IP}"
  read -rp "  当前在哪台机器 [1/2/3]: " _node
  case "$_node" in
    1) CURRENT_IP="$NODE1_IP"; NODE_ID=1 ;;
    2) CURRENT_IP="$NODE2_IP"; NODE_ID=2 ;;
    3) CURRENT_IP="$NODE3_IP"; NODE_ID=3 ;;
    *) error "无效选择" ;;
  esac
fi

echo ""
ask_password REDIS_PASSWORD "Redis 集群密码"

save_state
success "所有参数已保存至 ${STATE_FILE}"

REDIS_IMAGE="registry.cn-hangzhou.aliyuncs.com/sxxpqp/redis:${REDIS_VERSION}"

# 本机主节点和从节点编号
# Node1: master-1(6379) slave-2(6380)
# Node2: master-2(6379) slave-3(6380)
# Node3: master-3(6379) slave-1(6380)
MASTER_NUM=$NODE_ID
case "$NODE_ID" in
  1) SLAVE_NUM=2 ;;
  2) SLAVE_NUM=3 ;;
  3) SLAVE_NUM=1 ;;
esac

MASTER_CTR="redis-master-${MASTER_NUM}"
SLAVE_CTR="redis-slave-${SLAVE_NUM}"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  部署参数确认${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
printf "  %-18s: %s\n" "Redis 镜像"   "${REDIS_IMAGE}"
printf "  %-18s: %s\n" "数据目录"     "${DATA_DIR}"
printf "  %-18s: %s\n" "部署目录"     "${DEPLOY_DIR}"
printf "  %-18s: %s\n" "Node1"        "${NODE1_IP}"
printf "  %-18s: %s\n" "Node2"        "${NODE2_IP}"
printf "  %-18s: %s\n" "Node3"        "${NODE3_IP}"
printf "  %-18s: %s\n" "当前节点"     "Node${NODE_ID} (${CURRENT_IP})"
echo ""
echo -e "  ${BOLD}本机容器:${NC}"
printf "  :%-6s  %-25s  %s\n" "6379" "${MASTER_CTR}" "master-${MASTER_NUM} (主)"
printf "  :%-6s  %-25s  %s\n" "6380" "${SLAVE_CTR}"  "slave-${SLAVE_NUM}  (从)"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
read -rp "确认以上信息，开始部署？[y/N]: " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && { echo -e "${YELLOW}已取消${NC}"; exit 0; }

# ================================================================
# 二、系统准备
# ================================================================
title "Step 2 / 4  系统环境准备"

info "创建目录..."
mkdir -p \
  "${DEPLOY_DIR}/conf" \
  "${DATA_DIR}/master/data" \
  "${DATA_DIR}/master/logs" \
  "${DATA_DIR}/slave/data" \
  "${DATA_DIR}/slave/logs"
chmod -R 777 "${DATA_DIR}"
success "目录创建完成"

info "设置系统参数（Redis 性能优化）..."
grep -q "vm.overcommit_memory" /etc/sysctl.conf || \
  echo "vm.overcommit_memory = 1" >> /etc/sysctl.conf
grep -q "net.core.somaxconn" /etc/sysctl.conf || \
  echo "net.core.somaxconn = 65535" >> /etc/sysctl.conf
grep -q "net.ipv4.tcp_max_syn_backlog" /etc/sysctl.conf || \
  echo "net.ipv4.tcp_max_syn_backlog = 65535" >> /etc/sysctl.conf
sysctl -p &>/dev/null || true

# 关闭透明大页（Redis 强烈建议）
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
grep -q "transparent_hugepage" /etc/rc.local 2>/dev/null || \
  echo "echo never > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.local 2>/dev/null || true
success "系统参数设置完成"

info "开放防火墙端口..."
PORTS=(6379 6380 16379 16380)
if command -v firewall-cmd &>/dev/null; then
  for port in "${PORTS[@]}"; do
    firewall-cmd --permanent --add-port=${port}/tcp &>/dev/null || true
  done
  firewall-cmd --reload &>/dev/null || true
  success "firewalld 规则已添加"
elif command -v ufw &>/dev/null; then
  for port in "${PORTS[@]}"; do ufw allow ${port}/tcp &>/dev/null || true; done
  success "ufw 规则已添加"
else
  warn "请手动开放端口: ${PORTS[*]}"
fi

# ================================================================
# 三、生成配置文件
# ================================================================
title "Step 3 / 4  生成配置文件"

# 清理残留
for _f in \
  "${DEPLOY_DIR}/conf/master.conf" \
  "${DEPLOY_DIR}/conf/slave.conf" \
  "${DEPLOY_DIR}/docker-compose.yml"; do
  [[ -d "$_f" ]] && rm -rf "$_f"
  [[ -f "$_f" ]] && rm -f "$_f"
done

# ── Master 配置 ───────────────────────────────────────────────
info "生成 conf/master.conf ..."
cat > "${DEPLOY_DIR}/conf/master.conf" << EOF
# Redis Cluster Master 配置
bind 0.0.0.0
port 6379
protected-mode no

# 集群
cluster-enabled yes
cluster-config-file /data/nodes.conf
cluster-node-timeout 15000
cluster-announce-ip ${CURRENT_IP}
cluster-announce-port 6379
cluster-announce-bus-port 16379

# 认证
requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}

# 持久化
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
save 3600 1
save 300 100
save 60 10000
dbfilename dump.rdb
dir /data

# 性能
maxmemory-policy allkeys-lru
tcp-keepalive 300
timeout 0
tcp-backlog 65535
hz 10
loglevel notice
logfile /logs/redis.log
EOF
success "master.conf 生成完成"

# ── Slave 配置 ────────────────────────────────────────────────
info "生成 conf/slave.conf ..."
cat > "${DEPLOY_DIR}/conf/slave.conf" << EOF
# Redis Cluster Slave 配置
bind 0.0.0.0
port 6380
protected-mode no

# 集群
cluster-enabled yes
cluster-config-file /data/nodes.conf
cluster-node-timeout 15000
cluster-announce-ip ${CURRENT_IP}
cluster-announce-port 6380
cluster-announce-bus-port 16380

# 认证
requirepass ${REDIS_PASSWORD}
masterauth ${REDIS_PASSWORD}

# 持久化
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
save 3600 1
save 300 100
save 60 10000
dbfilename dump.rdb
dir /data

# 性能
maxmemory-policy allkeys-lru
tcp-keepalive 300
timeout 0
tcp-backlog 65535
hz 10
loglevel notice
logfile /logs/redis.log
EOF
success "slave.conf 生成完成"

# ── docker-compose.yml ────────────────────────────────────────
info "生成 docker-compose.yml ..."
cat > "${DEPLOY_DIR}/docker-compose.yml" << EOF
version: '3.8'

services:
  # ── Master ───────────────────────────────────────────────────
  redis-master:
    image: ${REDIS_IMAGE}
    container_name: ${MASTER_CTR}
    hostname: ${CURRENT_IP}
    restart: always
    network_mode: host
    command: redis-server /etc/redis/master.conf
    volumes:
      - ${DATA_DIR}/master/data:/data
      - ${DATA_DIR}/master/logs:/logs
      - ${DEPLOY_DIR}/conf/master.conf:/etc/redis/master.conf:ro
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD", "redis-cli", "-p", "6379", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"

  # ── Slave ────────────────────────────────────────────────────
  redis-slave:
    image: ${REDIS_IMAGE}
    container_name: ${SLAVE_CTR}
    hostname: ${CURRENT_IP}
    restart: always
    network_mode: host
    command: redis-server /etc/redis/slave.conf
    volumes:
      - ${DATA_DIR}/slave/data:/data
      - ${DATA_DIR}/slave/logs:/logs
      - ${DEPLOY_DIR}/conf/slave.conf:/etc/redis/slave.conf:ro
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD", "redis-cli", "-p", "6380", "-a", "${REDIS_PASSWORD}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
EOF
success "docker-compose.yml 生成完成"

# ================================================================
# 三B、生成初始化脚本（仅 Node1）
# ================================================================
if [[ "$NODE_ID" == "1" ]]; then
  mkdir -p "${DEPLOY_DIR}/scripts"
  info "生成 scripts/init_cluster.sh ..."
  cat > "${DEPLOY_DIR}/scripts/init_cluster.sh" << 'INITEOF'
#!/bin/bash
# ================================================================
# Redis Cluster 初始化脚本
# 三台机器全部部署完成后，在 Node1 执行一次
# ================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

STATE_FILE="$(cd "$(dirname "$0")" && pwd)/../.deploy_redis_state"
[[ -f "$STATE_FILE" ]] && source "$STATE_FILE" || error "找不到状态文件: $STATE_FILE"

for VAR in NODE1_IP NODE2_IP NODE3_IP REDIS_PASSWORD; do
  [[ -n "${!VAR:-}" ]] || error "$VAR 未设置，请检查状态文件"
done

N1="$NODE1_IP"; N2="$NODE2_IP"; N3="$NODE3_IP"
PASS="$REDIS_PASSWORD"

echo -e "\n${BOLD}Redis Cluster 初始化${NC}"
echo -e "节点: ${N1} / ${N2} / ${N3}\n"

# ── 检查所有节点是否可达 ──────────────────────────────────────
info "检查所有 6 个节点连通性..."
ALL_NODES=(
  "${N1}:6379" "${N1}:6380"
  "${N2}:6379" "${N2}:6380"
  "${N3}:6379" "${N3}:6380"
)
for node in "${ALL_NODES[@]}"; do
  host="${node%:*}"; port="${node#*:}"
  if docker exec redis-master-1 redis-cli -h "$host" -p "$port" -a "$PASS" \
      --no-auth-warning ping 2>/dev/null | grep -q "PONG"; then
    success "$node ✓"
  else
    error "$node 无法连接，请确认该节点已部署并 healthy"
  fi
done

# ── 创建集群 ──────────────────────────────────────────────────
echo ""
info "创建 Redis Cluster（3主3从）..."
echo "yes" | docker exec -i redis-master-1 redis-cli \
  -a "$PASS" --no-auth-warning \
  --cluster create \
  ${N1}:6379 ${N2}:6379 ${N3}:6379 \
  ${N1}:6380 ${N2}:6380 ${N3}:6380 \
  --cluster-replicas 1

# ── 验证集群状态 ──────────────────────────────────────────────
echo ""
info "验证集群状态..."
sleep 3
docker exec redis-master-1 redis-cli \
  -h "${N1}" -p 6379 \
  -a "$PASS" --no-auth-warning \
  cluster info | grep -E "cluster_state|cluster_slots|cluster_known_nodes|cluster_size"

echo ""
info "集群节点详情..."
docker exec redis-master-1 redis-cli \
  -h "${N1}" -p 6379 \
  -a "$PASS" --no-auth-warning \
  cluster nodes

echo ""
success "Redis Cluster 初始化完成！"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${BOLD}应用连接串:${NC}"
echo -e "  ${GREEN}${N1}:6379,${N2}:6379,${N3}:6379${NC}"
echo -e "  密码: ${PASS}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}常用运维命令:${NC}"
echo -e "  # 查看集群状态"
echo -e "  docker exec redis-master-1 redis-cli -a ${PASS} --no-auth-warning cluster info"
echo -e "  # 查看节点列表"
echo -e "  docker exec redis-master-1 redis-cli -a ${PASS} --no-auth-warning cluster nodes"
echo -e "  # 连接集群"
echo -e "  docker exec -it redis-master-1 redis-cli -c -h ${N1} -p 6379 -a ${PASS} --no-auth-warning"
INITEOF
  chmod 700 "${DEPLOY_DIR}/scripts/init_cluster.sh"
  # 修正状态文件路径
  sed -i "s|STATE_FILE=.*|STATE_FILE=\"${STATE_FILE}\"|" "${DEPLOY_DIR}/scripts/init_cluster.sh"
  success "init_cluster.sh 生成完成"
fi

# ================================================================
# 四、启动服务
# ================================================================
title "Step 4 / 4  启动服务"

cd "${DEPLOY_DIR}"
info "拉取镜像..."
docker compose pull

info "启动 Master 和 Slave..."
docker compose up -d

info "等待 ${MASTER_CTR} healthy..."
wait_healthy "${MASTER_CTR}" 24
echo ""

info "等待 ${SLAVE_CTR} healthy..."
wait_healthy "${SLAVE_CTR}" 24
echo ""

# ================================================================
# 完成提示
# ================================================================
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Node${NODE_ID} (${CURRENT_IP}) 部署完成 ✓${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
printf "  :%-6s  %-25s  %s\n" "6379" "${MASTER_CTR}" "master-${MASTER_NUM}"
printf "  :%-6s  %-25s  %s\n" "6380" "${SLAVE_CTR}"  "slave-${SLAVE_NUM}"
echo ""
printf "  %-20s: %s\n" "配置目录"  "${DEPLOY_DIR}"
printf "  %-20s: %s\n" "数据目录"  "${DATA_DIR}"
printf "  %-20s: %s\n" "状态文件"  "${STATE_FILE}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}💡 下一步: 三台全部部署完成后，在 Node1 执行集群初始化:${NC}"
echo -e "   ${BOLD}bash /opt/redis-cluster/scripts/init_cluster.sh${NC}"
echo ""
echo -e "${YELLOW}💡 如需修改参数: 编辑 ${STATE_FILE} 删除对应行，重新运行脚本${NC}"



