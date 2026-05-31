#!/bin/bash
# ================================================================
# RocketMQ 3主3从集群 三节点生产部署脚本
# 镜像: apache/rocketmq:5.3.2 (阿里云镜像)
#
# 集群架构（主从跨机器，容错最优）:
#   Node1: namesrv + broker-a-master(:10911) + broker-b-slave(:10921)
#   Node2: namesrv + broker-b-master(:10921) + broker-c-slave(:10931)
#   Node3: namesrv + broker-c-master(:10931) + broker-a-slave(:10911)
#   Node1 额外: dashboard(:8081)
#
# 用法: bash deploy_rocketmq.sh
# 参数缓存到 .deploy_rocketmq_state，下次运行自动跳过
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

STATE_FILE="$(cd "$(dirname "$0")" && pwd)/.deploy_rocketmq_state"

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    echo -e "${CYAN}[INFO]${NC}  检测到状态文件: ${STATE_FILE}"
    echo -e "${CYAN}[INFO]${NC}  已缓存的参数将自动跳过输入\n"
  fi
}

save_state() {
  cat > "$STATE_FILE" << STATEOF
# RocketMQ 集群部署状态 — 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
RMQ_VERSION=${RMQ_VERSION:-}
DASHBOARD_VERSION=${DASHBOARD_VERSION:-}
DATA_DIR=${DATA_DIR:-}
DEPLOY_DIR=${DEPLOY_DIR:-}
NODE1_IP=${NODE1_IP:-}
NODE2_IP=${NODE2_IP:-}
NODE3_IP=${NODE3_IP:-}
NODE_ID=${NODE_ID:-}
CURRENT_IP=${CURRENT_IP:-}
RMQ_USER=${RMQ_USER:-}
RMQ_PASSWORD=${RMQ_PASSWORD:-}
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
    printf "  [%2d/%d] %-35s 状态: %-12s\r" "$i" "$max" "$name" "$STATUS"
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
  ____            _        _   __  __ ___
 |  _ \ ___   ___| | _____| |_|  \/  / _ \
 | |_) / _ \ / __| |/ / _ \ __| |\/| | | |
 |  _ < (_) | (__|   <  __/ |_| |  | | |_|
 |_| \_\___/ \___|_|\_\___|\__|_|  |_|\__\_\

      3主3从集群 v5.3.2 — 三节点生产部署向导
      Node1: namesrv + broker-a-master + broker-b-slave + proxy + dashboard
      Node2: namesrv + broker-b-master + broker-c-slave + proxy
      Node3: namesrv + broker-c-master + broker-a-slave + proxy
BANNER
echo -e "${NC}"

load_state

# ================================================================
# 一、收集参数
# ================================================================
title "Step 1 / 4  参数配置"

if [[ -n "${RMQ_VERSION:-}" ]]; then
  echo -e "  ${GREEN}✓ (缓存)${NC} RocketMQ 版本: ${BOLD}${RMQ_VERSION}${NC}"
else
  echo "    1) 5.3.2  (推荐)"
  echo "    2) 5.3.1"
  echo "    3) 自定义"
  read -rp "  请选择 [默认: 1]: " _ver
  case "${_ver:-1}" in
    1) RMQ_VERSION="5.3.2" ;;
    2) RMQ_VERSION="5.3.1" ;;
    3) read -rp "  版本号: " RMQ_VERSION ;;
    *) RMQ_VERSION="5.3.2" ;;
  esac
fi

if [[ -n "${DASHBOARD_VERSION:-}" ]]; then
  echo -e "  ${GREEN}✓ (缓存)${NC} Dashboard 版本: ${BOLD}${DASHBOARD_VERSION}${NC}"
else
  DASHBOARD_VERSION="2.0.0"
  echo -e "  Dashboard 版本: ${BOLD}${DASHBOARD_VERSION}${NC}（默认）"
fi

echo ""
ask DATA_DIR   "数据根目录"    "/data/rocketmq"
ask DEPLOY_DIR "部署配置目录"  "/opt/rocketmq-cluster"

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
ask          RMQ_USER     "Dashboard 用户名"  "admin"
ask_password RMQ_PASSWORD "Dashboard 密码"

save_state
success "所有参数已保存至 ${STATE_FILE}"

# ── 镜像和公共变量 ────────────────────────────────────────────
RMQ_IMAGE="registry.cn-hangzhou.aliyuncs.com/sxxpqp/rocketmq:${RMQ_VERSION}"
DASHBOARD_IMAGE="registry.cn-hangzhou.aliyuncs.com/sxxpqp/rocketmq-dashboard:${DASHBOARD_VERSION}"
NAMESRV_ADDR="${NODE1_IP}:9876;${NODE2_IP}:9876;${NODE3_IP}:9876"

# ── 按节点决定本机 broker 角色 ────────────────────────────────
# Node1: broker-a-master(10911)  broker-b-slave(10921)
# Node2: broker-b-master(10921)  broker-c-slave(10931)
# Node3: broker-c-master(10931)  broker-a-slave(10911)
case "$NODE_ID" in
  1)
    M_NAME="broker-a"; M_ID=0; M_ROLE="ASYNC_MASTER"; M_PORT=10911
    S_NAME="broker-b"; S_ID=1; S_ROLE="SLAVE";        S_PORT=10921
    ;;
  2)
    M_NAME="broker-b"; M_ID=0; M_ROLE="ASYNC_MASTER"; M_PORT=10921
    S_NAME="broker-c"; S_ID=1; S_ROLE="SLAVE";        S_PORT=10931
    ;;
  3)
    M_NAME="broker-c"; M_ID=0; M_ROLE="ASYNC_MASTER"; M_PORT=10931
    S_NAME="broker-a"; S_ID=1; S_ROLE="SLAVE";        S_PORT=10911
    ;;
esac

M_CTR="${M_NAME}-master-n${NODE_ID}"
S_CTR="${S_NAME}-slave-n${NODE_ID}"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  部署参数确认${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
printf "  %-18s: %s\n" "RocketMQ 镜像"   "${RMQ_IMAGE}"
printf "  %-18s: %s\n" "数据目录"         "${DATA_DIR}"
printf "  %-18s: %s\n" "部署目录"         "${DEPLOY_DIR}"
printf "  %-18s: %s\n" "Node1"            "${NODE1_IP}"
printf "  %-18s: %s\n" "Node2"            "${NODE2_IP}"
printf "  %-18s: %s\n" "Node3"            "${NODE3_IP}"
printf "  %-18s: %s\n" "当前节点"         "Node${NODE_ID} (${CURRENT_IP})"
echo ""
echo -e "  ${BOLD}本机容器:${NC}"
printf "  :%-6s  %-30s  %s\n" "9876"      "namesrv${NODE_ID}"   "NameServer"
printf "  :%-6s  %-30s  %s\n" "${M_PORT}" "${M_CTR}"            "${M_ROLE}"
printf "  :%-6s  %-30s  %s\n" "${S_PORT}" "${S_CTR}"            "${S_ROLE}"
printf "  :%-6s  %-30s  %s\n" "8080/8081" "rmqproxy${NODE_ID}"  "Proxy gRPC/Remoting"
[[ "$NODE_ID" == "1" ]] && \
printf "  :%-6s  %-30s  %s\n" "9999"      "rocketmq-dashboard"  "控制台"
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
  "${DATA_DIR}/namesrv/logs" \
  "${DATA_DIR}/${M_NAME}-master/logs" \
  "${DATA_DIR}/${M_NAME}-master/store" \
  "${DATA_DIR}/${S_NAME}-slave/logs" \
  "${DATA_DIR}/${S_NAME}-slave/store"
[[ "$NODE_ID" == "1" ]] && mkdir -p "${DATA_DIR}/dashboard"
chmod -R 777 "${DATA_DIR}"
success "目录创建完成"

info "设置系统参数..."
grep -q "vm.max_map_count" /etc/sysctl.conf || echo "vm.max_map_count = 262144"  >> /etc/sysctl.conf
grep -q "fs.file-max"      /etc/sysctl.conf || echo "fs.file-max = 655360"       >> /etc/sysctl.conf
grep -q "nofile 65536" /etc/security/limits.conf || {
  echo "* soft nofile 65536" >> /etc/security/limits.conf
  echo "* hard nofile 65536" >> /etc/security/limits.conf
}
sysctl -p &>/dev/null || true
success "系统参数设置完成"

info "开放防火墙端口..."
PORTS=(9876 8080 8081 9999 10909 10910 10911 10912 10921 10922 10931 10932)
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

# 清理残留同名目录
for _f in \
  "${DEPLOY_DIR}/conf/master.conf" \
  "${DEPLOY_DIR}/conf/slave.conf" \
  "${DEPLOY_DIR}/conf/rmq-proxy.json" \
  "${DEPLOY_DIR}/docker-compose.yml"; do
  [[ -d "$_f" ]] && rm -rf "$_f"
  [[ -f "$_f" ]] && rm -f "$_f"
done

# ── Master broker 配置 ────────────────────────────────────────
info "生成 conf/master.conf (${M_NAME} ${M_ROLE} :${M_PORT})..."
cat > "${DEPLOY_DIR}/conf/master.conf" << EOF
brokerClusterName=RocketMQ-Cluster
brokerName=${M_NAME}
brokerId=${M_ID}
brokerRole=${M_ROLE}

# 网络
brokerIP1=${CURRENT_IP}
listenPort=${M_PORT}
namesrvAddr=${NAMESRV_ADDR}

# 存储（容器内路径）
storePathRootDir=/data/master/store
storePathCommitLog=/data/master/store/commitlog
storePathConsumerQueue=/data/master/store/consumequeue
storePathIndex=/data/master/store/index
storeCheckpoint=/data/master/store/checkpoint
abortFile=/data/master/store/abort

# 性能
flushDiskType=ASYNC_FLUSH
autoCreateTopicEnable=true
autoCreateSubscriptionGroup=true
defaultTopicQueueNums=8
deleteWhen=04
fileReservedTime=72
mapedFileSizeCommitLog=1073741824
mapedFileSizeConsumeQueue=300000
maxMessageSize=65536
sendMessageThreadPoolNums=128
pullMessageThreadPoolNums=128
EOF
success "master.conf 生成完成"

# ── Slave broker 配置 ─────────────────────────────────────────
info "生成 conf/slave.conf (${S_NAME} ${S_ROLE} :${S_PORT})..."
cat > "${DEPLOY_DIR}/conf/slave.conf" << EOF
brokerClusterName=RocketMQ-Cluster
brokerName=${S_NAME}
brokerId=${S_ID}
brokerRole=${S_ROLE}

# 网络
brokerIP1=${CURRENT_IP}
listenPort=${S_PORT}
namesrvAddr=${NAMESRV_ADDR}

# 存储（容器内路径）
storePathRootDir=/data/slave/store
storePathCommitLog=/data/slave/store/commitlog
storePathConsumerQueue=/data/slave/store/consumequeue
storePathIndex=/data/slave/store/index
storeCheckpoint=/data/slave/store/checkpoint
abortFile=/data/slave/store/abort

# 性能
flushDiskType=ASYNC_FLUSH
autoCreateTopicEnable=true
autoCreateSubscriptionGroup=true
defaultTopicQueueNums=8
deleteWhen=04
fileReservedTime=72
mapedFileSizeCommitLog=1073741824
mapedFileSizeConsumeQueue=300000
maxMessageSize=65536
sendMessageThreadPoolNums=64
pullMessageThreadPoolNums=64
EOF
success "slave.conf 生成完成"

# ── docker-compose.yml ────────────────────────────────────────
info "生成 conf/rmq-proxy.json ..."
cat > "${DEPLOY_DIR}/conf/rmq-proxy.json" << EOF
{
  "rocketMQClusterName": "RocketMQ-Cluster",
  "nameSrvAddr": "${NAMESRV_ADDR}"
}
EOF
success "rmq-proxy.json 生成完成"

info "生成 docker-compose.yml ..."
cat > "${DEPLOY_DIR}/docker-compose.yml" << EOF
version: '3.8'

services:
  # ── NameServer ───────────────────────────────────────────────
  namesrv:
    image: ${RMQ_IMAGE}
    container_name: namesrv${NODE_ID}
    hostname: ${CURRENT_IP}
    restart: always
    network_mode: host
    command: sh mqnamesrv
    environment:
      - JAVA_OPT_EXT=-server -Xms512m -Xmx512m -Xmn256m
    volumes:
      - ${DATA_DIR}/namesrv/logs:/home/rocketmq/logs/rocketmqlogs
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD-SHELL", "curl -s --connect-timeout 3 http://127.0.0.1:9876; test $? -le 52"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 20s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"

  # ── Master: ${M_NAME} ${M_ROLE} :${M_PORT} ───────────────────
  broker-master:
    image: ${RMQ_IMAGE}
    container_name: ${M_CTR}
    hostname: ${CURRENT_IP}
    restart: always
    network_mode: host
    command: sh mqbroker -c /etc/rocketmq/master.conf
    environment:
      - JAVA_OPT_EXT=-server -Xms1g -Xmx2g -Xmn512m -XX:+UseG1GC
      - NAMESRV_ADDR=${NAMESRV_ADDR}
    volumes:
      - ${DATA_DIR}/${M_NAME}-master/logs:/home/rocketmq/logs/rocketmqlogs
      - ${DATA_DIR}/${M_NAME}-master/store:/data/master/store
      - ${DEPLOY_DIR}/conf/master.conf:/etc/rocketmq/master.conf:ro
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    depends_on:
      namesrv:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -s --connect-timeout 3 http://127.0.0.1:${M_PORT}; test $? -le 52"]
      interval: 15s
      timeout: 5s
      retries: 12
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"

  # ── Slave: ${S_NAME} ${S_ROLE} :${S_PORT} ────────────────────
  broker-slave:
    image: ${RMQ_IMAGE}
    container_name: ${S_CTR}
    hostname: ${CURRENT_IP}
    restart: always
    network_mode: host
    command: sh mqbroker -c /etc/rocketmq/slave.conf
    environment:
      - JAVA_OPT_EXT=-server -Xms512m -Xmx1g -Xmn256m -XX:+UseG1GC
      - NAMESRV_ADDR=${NAMESRV_ADDR}
    volumes:
      - ${DATA_DIR}/${S_NAME}-slave/logs:/home/rocketmq/logs/rocketmqlogs
      - ${DATA_DIR}/${S_NAME}-slave/store:/data/slave/store
      - ${DEPLOY_DIR}/conf/slave.conf:/etc/rocketmq/slave.conf:ro
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    depends_on:
      namesrv:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -s --connect-timeout 3 http://127.0.0.1:${S_PORT}; test $? -le 52"]
      interval: 15s
      timeout: 5s
      retries: 12
      start_period: 40s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
EOF

# Proxy 每台都部署（5.x 新增组件，客户端通过 proxy 访问）
cat >> "${DEPLOY_DIR}/docker-compose.yml" << EOF

  # ── Proxy（5.x 新增，客户端统一入口）────────────────────────
  proxy:
    image: ${RMQ_IMAGE}
    container_name: rmqproxy${NODE_ID}
    hostname: ${CURRENT_IP}
    restart: on-failure
    network_mode: host
    command: sh mqproxy
    environment:
      - NAMESRV_ADDR=${NAMESRV_ADDR}
      - JAVA_OPT_EXT=-server -Xms512m -Xmx512m
    volumes:
      - ${DEPLOY_DIR}/conf/rmq-proxy.json:/home/rocketmq/rocketmq-5.3.2/conf/rmq-proxy.json:ro
    depends_on:
      namesrv:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -s --connect-timeout 3 http://127.0.0.1:8080; test $? -le 52"]
      interval: 15s
      timeout: 5s
      retries: 12
      start_period: 60s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
EOF

# Dashboard 仅 Node1
if [[ "$NODE_ID" == "1" ]]; then
  cat >> "${DEPLOY_DIR}/docker-compose.yml" << EOF

  # ── Dashboard ────────────────────────────────────────────────
  dashboard:
    image: ${DASHBOARD_IMAGE}
    container_name: rocketmq-dashboard
    restart: always
    network_mode: host
    environment:
      - JAVA_OPTS=-server -Xms256m -Xmx512m -Dserver.port=9999
      - rocketmq.config.namesrvAddr=${NAMESRV_ADDR}
      - rocketmq.config.loginRequired=false
      - rocketmq.config.dataPath=/tmp/rocketmq-console/data
    volumes:
      - ${DATA_DIR}/dashboard:/tmp/rocketmq-console/data
    depends_on:
      namesrv:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -s --connect-timeout 3 http://127.0.0.1:9999; test $? -le 52"]
      interval: 15s
      timeout: 5s
      retries: 12
      start_period: 60s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
EOF
fi

success "docker-compose.yml 生成完成"

# ================================================================
# 四、启动服务
# ================================================================
title "Step 4 / 4  启动服务"

cd "${DEPLOY_DIR}"
info "拉取镜像..."
docker compose pull

info "启动 NameServer..."
docker compose up -d namesrv
wait_healthy "namesrv${NODE_ID}"
echo ""

info "启动 broker-master (${M_CTR}) 和 broker-slave (${S_CTR})..."
docker compose up -d broker-master broker-slave

info "等待 broker-master healthy..."
wait_healthy "${M_CTR}" 24
echo ""

info "等待 broker-slave healthy..."
wait_healthy "${S_CTR}" 24
echo ""

if [[ "$NODE_ID" == "1" ]]; then
  info "启动 Dashboard..."
  docker compose up -d dashboard
  info "等待 Dashboard healthy（约60秒）..."
  wait_healthy "rocketmq-dashboard" 24
  echo ""
fi

warn "Proxy 需要三台集群全部就绪后再启动"
info "当前节点 Proxy 稍后手动启动: docker compose up -d proxy"
info "三台全部部署完成后，各节点执行: docker compose up -d proxy"

# ================================================================
# 完成提示
# ================================================================
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Node${NODE_ID} (${CURRENT_IP}) 部署完成 ✓${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
printf "  :%-6s  %-30s  %s\n" "9876"      "namesrv${NODE_ID}"          "NameServer"
printf "  :%-6s  %-30s  %s\n" "${M_PORT}" "${M_CTR}"                   "${M_ROLE}"
printf "  :%-6s  %-30s  %s\n" "${S_PORT}" "${S_CTR}"                   "${S_ROLE}"
printf "  :%-6s  %-30s  %s\n" "8080/8081" "rmqproxy${NODE_ID}"         "Proxy gRPC/Remoting"
[[ "$NODE_ID" == "1" ]] && \
printf "  :%-6s  %-30s  %s\n" "9999" "rocketmq-dashboard" "http://${NODE1_IP}:9999"
echo ""
echo -e "  ${BOLD}应用连接配置（二选一）:${NC}"
echo -e "  ${YELLOW}# 方式1: 通过 Proxy gRPC（推荐 5.x SDK）${NC}"
echo -e "  ${GREEN}${NODE1_IP}:8080;${NODE2_IP}:8080;${NODE3_IP}:8080${NC}"
echo -e "  ${YELLOW}# 方式2: 通过 Proxy Remoting（兼容 4.x SDK）${NC}"
echo -e "  ${GREEN}${NODE1_IP}:8081;${NODE2_IP}:8081;${NODE3_IP}:8081${NC}"
echo -e "  ${YELLOW}# 方式3: 直连 NameServer${NC}"
echo -e "  ${GREEN}${NAMESRV_ADDR}${NC}"
[[ "$NODE_ID" == "1" ]] && echo -e "  ${YELLOW}# Dashboard${NC}" && \
echo -e "  ${GREEN}http://${NODE1_IP}:9999  用户: ${RMQ_USER}${NC}"
echo ""
printf "  %-20s: %s\n" "配置目录"  "${DEPLOY_DIR}"
printf "  %-20s: %s\n" "数据目录"  "${DATA_DIR}"
printf "  %-20s: %s\n" "状态文件"  "${STATE_FILE}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}💡 下一步: 三台全部部署完成后，各节点执行:${NC}"
echo -e "   ${BOLD}cd ${DEPLOY_DIR} && docker compose up -d proxy${NC}"
echo ""
echo -e "${YELLOW}💡 如需修改参数: 编辑 ${STATE_FILE} 删除对应行，重新运行脚本${NC}"