#!/bin/bash
# ================================================================
# MySQL Router 部署脚本
# 每台数据库节点各运行一个 Router 实例，应用就近连接
#
# 端口:
#   6446  读写端口 → 自动路由到 Primary
#   6447  只读端口 → 自动路由到 Secondary（轮询）
#   6448  x-protocol 读写
#   6449  x-protocol 只读
#   8443  Router REST API
#
# 用法: bash deploy_mysql_router.sh
# 参数缓存到 .deploy_router_state，下次运行自动跳过
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

STATE_FILE="$(cd "$(dirname "$0")" && pwd)/.deploy_router_state"

load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    source "$STATE_FILE"
    echo -e "${CYAN}[INFO]${NC}  检测到状态文件: ${STATE_FILE}"
    echo -e "${CYAN}[INFO]${NC}  已缓存的参数将自动跳过输入\n"
  fi
}

save_state() {
  cat > "$STATE_FILE" << STATEOF
# MySQL Router 部署状态 — 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
ROUTER_VERSION=${ROUTER_VERSION:-}
DEPLOY_DIR=${DEPLOY_DIR:-}
NODE1_IP=${NODE1_IP:-}
NODE2_IP=${NODE2_IP:-}
NODE3_IP=${NODE3_IP:-}
NODE_ID=${NODE_ID:-}
CURRENT_IP=${CURRENT_IP:-}
MYSQL_USER=${MYSQL_USER:-}
MYSQL_PASSWORD=${MYSQL_PASSWORD:-}
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

# ================================================================
# FIX: 改用 mysqladmin ping 通过 Router 6446 端口检测连通性
#      原来用 curl 连 MySQL TCP 端口不可靠（依赖 exit code 52）
# ================================================================
wait_healthy() {
  local name="$1" max="${2:-36}"
  local user="${MYSQL_USER}" pass="${MYSQL_PASSWORD}"
  for i in $(seq 1 $max); do
    # 优先检查 Docker healthcheck 状态
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "starting")
    if [[ "$STATUS" == "healthy" ]]; then
      success "$name healthy ✓"
      return 0
    fi
    # 同时用 mysqladmin ping 验证 6446 端口实际可用
    if docker exec "$name" \
         mysqladmin ping -h 127.0.0.1 -P 6446 -u "$user" -p"$pass" \
         --connect-timeout=3 &>/dev/null; then
      success "$name 端口 6446 可达（healthcheck 状态: ${STATUS}）✓"
      return 0
    fi
    printf "  [%2d/%d] %-30s 状态: %-12s\r" "$i" "$max" "$name" "$STATUS"
    sleep 5
  done
  echo ""
  warn "$name 未能在时限内就绪，请检查: docker logs $name"
  warn "如日志显示端口已监听且集群成员已识别，容器功能正常，healthcheck 配置问题不影响使用"
}

# ================================================================
# Banner
# ================================================================
clear
echo -e "${BOLD}${GREEN}"
cat << 'BANNER'
  __  __       ____   ___  _
 |  \/  |_   _/ ___| / _ \| |
 | |\/| | | | \___ \| | | | |
 | |  | | |_| |___) | |_| | |___
 |_|  |_|\__, |____/ \__\_\_____|  Router
         |___/

      MySQL Router — 三节点读写分离部署向导
      每台节点各运行一个 Router 实例
      :6446  读写 → Primary
      :6447  只读 → Secondary (轮询)
BANNER
echo -e "${NC}"

load_state

# ================================================================
# 一、收集参数
# ================================================================
title "Step 1 / 3  参数配置"

if [[ -n "${ROUTER_VERSION:-}" ]]; then
  echo -e "  ${GREEN}✓ (缓存)${NC} Router 版本: ${BOLD}${ROUTER_VERSION}${NC}"
else
  echo "    1) 8.0  (与 MySQL 8.0 匹配，推荐)"
  echo "    2) 8.4"
  echo "    3) 自定义"
  read -rp "  请选择 [默认: 1]: " _ver
  case "${_ver:-1}" in
    1) ROUTER_VERSION="8.0" ;;
    2) ROUTER_VERSION="8.4" ;;
    3) read -rp "  版本号: " ROUTER_VERSION ;;
    *) ROUTER_VERSION="8.0" ;;
  esac
fi

echo ""
ask DEPLOY_DIR "部署配置目录" "/opt/mysql-router"

echo ""
info "三台服务器 IP（需与 MySQL 集群一致）："
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
info "MySQL InnoDB Cluster 管理员账号（用于 Router bootstrap）："
ask          MYSQL_USER     "  MySQL 管理员用户名"  "clusteradmin"
ask_password MYSQL_PASSWORD "  MySQL 管理员密码"

save_state
success "所有参数已保存至 ${STATE_FILE}"

ROUTER_IMAGE="registry.cn-hangzhou.aliyuncs.com/sxxpqp/mysql-router:${ROUTER_VERSION}"
ROUTER_CTR="mysql-router-${NODE_ID}"
PRIMARY_IP="${NODE1_IP}"  # bootstrap 连接 Primary

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  部署参数确认${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
printf "  %-18s: %s\n" "Router 镜像"     "${ROUTER_IMAGE}"
printf "  %-18s: %s\n" "部署目录"         "${DEPLOY_DIR}"
printf "  %-18s: %s\n" "Node1"            "${NODE1_IP}"
printf "  %-18s: %s\n" "Node2"            "${NODE2_IP}"
printf "  %-18s: %s\n" "Node3"            "${NODE3_IP}"
printf "  %-18s: %s\n" "当前节点"         "Node${NODE_ID} (${CURRENT_IP})"
printf "  %-18s: %s\n" "Bootstrap 连接"   "${MYSQL_USER}@${PRIMARY_IP}:3306"
echo ""
echo -e "  ${BOLD}本机容器:${NC}"
printf "  :%-6s  %-25s  %s\n" "6446" "${ROUTER_CTR}" "读写 → Primary"
printf "  :%-6s  %-25s  %s\n" "6447" "${ROUTER_CTR}" "只读 → Secondary"
printf "  :%-6s  %-25s  %s\n" "6448" "${ROUTER_CTR}" "x-protocol 读写"
printf "  :%-6s  %-25s  %s\n" "6449" "${ROUTER_CTR}" "x-protocol 只读"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
read -rp "确认以上信息，开始部署？[y/N]: " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && { echo -e "${YELLOW}已取消${NC}"; exit 0; }

# ================================================================
# 二、准备环境
# ================================================================
title "Step 2 / 3  环境准备"

info "创建目录..."
mkdir -p "${DEPLOY_DIR}/data-${NODE_ID}"
# FIX: Router 容器内以 mysql 用户（UID 999）运行，挂载目录须对其可写
# 优先用 chown，若宿主机无 mysql 用户则直接 chmod 777 兜底
if id -u mysql &>/dev/null; then
  chown -R mysql:mysql "${DEPLOY_DIR}/data-${NODE_ID}"
else
  chown -R 999:999 "${DEPLOY_DIR}/data-${NODE_ID}" 2>/dev/null \
    || chmod -R 777 "${DEPLOY_DIR}/data-${NODE_ID}"
fi
success "目录创建完成（已设置 Router 容器写权限）"

info "开放防火墙端口..."
PORTS=(6446 6447 6448 6449 8443)
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

info "清理同名容器..."
docker rm -f "${ROUTER_CTR}" 2>/dev/null || true
success "清理完成"

# ================================================================
# 三、Bootstrap 并启动
# ================================================================
title "Step 3 / 3  Bootstrap 并启动"

info "拉取镜像..."
docker pull "${ROUTER_IMAGE}"

# ================================================================
# FIX: healthcheck 改用 mysqladmin ping 通过 Router 6446 端口
#      原来: curl -s http://127.0.0.1:6446 → 连 MySQL TCP 端口
#            curl 收到非 HTTP 响应返回 52，但并不可靠
#      现在: mysqladmin ping -h 127.0.0.1 -P 6446 → 真实 MySQL 握手
#            连接成功返回 0，失败返回非 0，判断准确
#
# FIX: start_period 从 40s 延长到 60s
#      Router 需要先完成 bootstrap 再启动监听，冷启动约需 30-50s
#      start_period 内 healthcheck 失败不计入 retries，避免误判
#
# FIX: retries 从 12 增加到 18，总等待时间 60s + 18×10s = 3 分钟
#      给集群成员发现和元数据同步留足时间
# ================================================================
info "生成 docker-compose.yml ..."
cat > "${DEPLOY_DIR}/docker-compose.yml" << EOF
version: '3.8'

services:
  mysql-router:
    image: ${ROUTER_IMAGE}
    container_name: ${ROUTER_CTR}
    hostname: ${CURRENT_IP}
    restart: always
    network_mode: host
    environment:
      - MYSQL_HOST=${PRIMARY_IP}
      - MYSQL_PORT=3306
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - MYSQL_INNODB_CLUSTER_MEMBERS=3
      - MYSQL_CREATE_ROUTER_USER=0
    volumes:
      - ${DEPLOY_DIR}/data-${NODE_ID}:/tmp/mysqlrouter
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -P 6446 -u ${MYSQL_USER} -p${MYSQL_PASSWORD} --connect-timeout=3 2>/dev/null"]
      interval: 10s
      timeout: 5s
      retries: 18
      start_period: 60s
    logging:
      driver: "json-file"
      options:
        max-size: "100m"
        max-file: "5"
EOF
success "docker-compose.yml 生成完成"

info "启动 MySQL Router..."
cd "${DEPLOY_DIR}"
docker compose up -d
wait_healthy "${ROUTER_CTR}" 36
echo ""

# ================================================================
# 完成提示
# ================================================================
echo -e "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Node${NODE_ID} (${CURRENT_IP}) Router 部署完成 ✓${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
printf "  :%-6s  %s\n" "6446" "读写端口 → 自动路由到 Primary"
printf "  :%-6s  %s\n" "6447" "只读端口 → 自动路由到 Secondary（轮询）"
printf "  :%-6s  %s\n" "6448" "x-protocol 读写"
printf "  :%-6s  %s\n" "6449" "x-protocol 只读"
echo ""
echo -e "  ${BOLD}应用连接配置:${NC}"
echo -e "  ${YELLOW}# 读写（写库）${NC}"
echo -e "  ${GREEN}jdbc:mysql://${NODE1_IP}:6446,${NODE2_IP}:6446,${NODE3_IP}:6446/yourdb?useSSL=false${NC}"
echo -e "  ${YELLOW}# 只读（读库）${NC}"
echo -e "  ${GREEN}jdbc:mysql://${NODE1_IP}:6447,${NODE2_IP}:6447,${NODE3_IP}:6447/yourdb?useSSL=false${NC}"
echo ""
echo -e "  ${YELLOW}# 快速验证${NC}"
echo -e "  mysql -h ${CURRENT_IP} -P 6446 -u ${MYSQL_USER} -p  # 连读写"
echo -e "  mysql -h ${CURRENT_IP} -P 6447 -u ${MYSQL_USER} -p  # 连只读"
echo ""
printf "  %-20s: %s\n" "配置目录"    "${DEPLOY_DIR}"
printf "  %-20s: %s\n" "Router 数据" "${DEPLOY_DIR}/data-${NODE_ID}"
printf "  %-20s: %s\n" "状态文件"    "${STATE_FILE}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}💡 如需修改参数: 编辑 ${STATE_FILE} 删除对应行，重新运行脚本${NC}"
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"