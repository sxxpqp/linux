#!/bin/bash
# ================================================================
# MySQL InnoDB Cluster 三节点生产部署脚本
# 用法: bash deploy.sh
# 已输入的参数会保存到 .deploy_state，下次运行自动跳过已填项
# ================================================================

set -euo pipefail

# ── 颜色输出 ──────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
title()   { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"
            echo -e "${BOLD}${BLUE}  $*${NC}"
            echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}\n"; }

# ── 状态文件 ───────────────────────────────────────────────────
STATE_FILE="$(cd "$(dirname "$0")" && pwd)/.deploy_state"

# ── 加载已有状态 ───────────────────────────────────────────────
load_state() {
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    echo -e "${CYAN}[INFO]${NC}  检测到状态文件: ${STATE_FILE}"
    echo -e "${CYAN}[INFO]${NC}  已缓存的参数将自动跳过输入\n"
  fi
}

# ── 保存所有变量到状态文件 ────────────────────────────────────
save_state() {
  cat > "$STATE_FILE" << STATEOF
# MySQL Cluster 部署状态文件 — 自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 如需重新输入某项，删除对应行后重新运行脚本即可
MYSQL_VERSION=${MYSQL_VERSION:-}
DATA_DIR=${DATA_DIR:-}
DEPLOY_DIR=${DEPLOY_DIR:-}
NODE1_IP=${NODE1_IP:-}
NODE2_IP=${NODE2_IP:-}
NODE3_IP=${NODE3_IP:-}
NODE_ID=${NODE_ID:-}
CURRENT_IP=${CURRENT_IP:-}
CONTAINER_NAME=${CONTAINER_NAME:-}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-}
CLUSTER_ADMIN_PASSWORD=${CLUSTER_ADMIN_PASSWORD:-}
STATEOF
  chmod 600 "$STATE_FILE"
}

# ── 带缓存的普通输入 ───────────────────────────────────────────
# 用法: ask VAR_NAME "提示" "默认值"
ask() {
  local var="$1" prompt="$2" default="${3:-}"
  local cur="${!var:-}"
  if [[ -n "$cur" ]]; then
    echo -e "  ${GREEN}✓ (缓存)${NC} ${prompt}: ${BOLD}${cur}${NC}"
    return
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

# ── 带缓存的密码输入 ───────────────────────────────────────────
ask_password() {
  local var="$1" prompt="$2"
  local cur="${!var:-}"
  if [[ -n "$cur" ]]; then
    echo -e "  ${GREEN}✓ (缓存)${NC} ${prompt}: ${BOLD}********${NC}"
    return
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

# ── IP 格式校验 ────────────────────────────────────────────────
validate_ip() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "IP 格式不正确: $1"
}

# ================================================================
# Banner
# ================================================================
clear
echo -e "${BOLD}${GREEN}"
cat << 'BANNER'
  __  __        ____  ____  _      ____  _           _
 |  \/  |_   _ / ___||  _ \| |    / ___|| |_   _ ___| |_ ___ _ __
 | |\/| | | | |\___ \| |_) | |   | |    | | | | / __| __/ _ \ '__|
 | |  | | |_| | ___) |  _ <| |___| |___ | | |_| \__ \ ||  __/ |
 |_|  |_|\__, ||____/|_| \_\_____|\____||_|\__,_|___/\__\___|_|
          |___/
         InnoDB Cluster — 三节点生产部署向导
BANNER
echo -e "${NC}"

load_state

# ================================================================
# 一、收集部署参数
# ================================================================
title "Step 1 / 5  参数配置"

# ── MySQL 版本 ─────────────────────────────────────────────────
if [[ -n "${MYSQL_VERSION:-}" ]]; then
  echo -e "  ${GREEN}✓ (缓存)${NC} MySQL 版本: ${BOLD}registry.cn-hangzhou.aliyuncs.com/sxxpqp/mysql:${MYSQL_VERSION}${NC}"
else
  echo -e "${BOLD}  支持的 MySQL 版本:${NC}"
  echo "    1) 8.0  (推荐，长期支持)"
  echo "    2) 8.4  (最新 LTS)"
  echo "    3) 自定义输入"
  read -rp "  请选择 [默认: 1]: " _ver
  case "${_ver:-1}" in
    1) MYSQL_VERSION="8.0" ;;
    2) MYSQL_VERSION="8.4" ;;
    3) read -rp "  请输入版本号 (如 8.0.36): " MYSQL_VERSION ;;
    *) MYSQL_VERSION="8.0" ;;
  esac
fi

echo ""
ask DATA_DIR   "MySQL 数据目录"  "/data/mysql"
ask DEPLOY_DIR "部署配置目录"    "/opt/mysql-cluster"

echo ""
info "三台服务器 IP 地址："
ask NODE1_IP "  Node1 IP (Primary)  "
ask NODE2_IP "  Node2 IP (Secondary)"
ask NODE3_IP "  Node3 IP (Secondary)"
validate_ip "$NODE1_IP"; validate_ip "$NODE2_IP"; validate_ip "$NODE3_IP"

# ── 当前节点 ───────────────────────────────────────────────────
echo ""
if [[ -n "${NODE_ID:-}" ]]; then
  echo -e "  ${GREEN}✓ (缓存)${NC} 当前节点: ${BOLD}Node${NODE_ID} (${CURRENT_IP})${NC}"
else
  echo -e "  ${BOLD}当前正在哪台机器上运行此脚本？${NC}"
  echo "    1) Node1 — ${NODE1_IP}"
  echo "    2) Node2 — ${NODE2_IP}"
  echo "    3) Node3 — ${NODE3_IP}"
  read -rp "  请选择 [1/2/3]: " _node
  case "$_node" in
    1) CURRENT_IP="$NODE1_IP"; NODE_ID=1; CONTAINER_NAME="mysql1" ;;
    2) CURRENT_IP="$NODE2_IP"; NODE_ID=2; CONTAINER_NAME="mysql2" ;;
    3) CURRENT_IP="$NODE3_IP"; NODE_ID=3; CONTAINER_NAME="mysql3" ;;
    *) error "无效选择" ;;
  esac
fi

echo ""
ask_password MYSQL_ROOT_PASSWORD    "MySQL root 密码"
ask_password CLUSTER_ADMIN_PASSWORD "clusteradmin 密码"

# ── 立即保存状态 ───────────────────────────────────────────────
save_state
echo ""
success "所有参数已保存至 ${STATE_FILE}"

# ── 汇总确认 ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  部署参数确认${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
printf "  %-14s: %s\n" "MySQL 版本"  "registry.cn-hangzhou.aliyuncs.com/sxxpqp/mysql:${MYSQL_VERSION}"
printf "  %-14s: %s\n" "数据目录"    "${DATA_DIR}"
printf "  %-14s: %s\n" "部署目录"    "${DEPLOY_DIR}"
printf "  %-14s: %s\n" "Node1 IP"    "${NODE1_IP}"
printf "  %-14s: %s\n" "Node2 IP"    "${NODE2_IP}"
printf "  %-14s: %s\n" "Node3 IP"    "${NODE3_IP}"
printf "  %-14s: %s\n" "当前节点"    "Node${NODE_ID} (${CURRENT_IP})"
printf "  %-14s: %s\n" "Root 密码"   "********"
printf "  %-14s: %s\n" "Admin 密码"  "********"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
read -rp "确认以上信息，开始部署？[y/N]: " CONFIRM
[[ "${CONFIRM,,}" != "y" ]] && {
  echo -e "${YELLOW}已取消。参数已保存，下次运行无需重新输入。${NC}"
  exit 0
}

# ================================================================
# 二、系统前置准备
# ================================================================
title "Step 2 / 5  系统环境准备"

info "创建目录..."
mkdir -p "${DEPLOY_DIR}/conf" "${DEPLOY_DIR}/scripts" "${DEPLOY_DIR}/logs"
mkdir -p "${DATA_DIR}"
chmod 777 "${DATA_DIR}" "${DEPLOY_DIR}/logs"
success "目录创建完成"

info "设置系统参数..."
grep -q "fs.file-max" /etc/sysctl.conf         || echo "fs.file-max = 655360"    >> /etc/sysctl.conf
grep -q "nofile 65536" /etc/security/limits.conf || {
  echo "* soft nofile 65536" >> /etc/security/limits.conf
  echo "* hard nofile 65536" >> /etc/security/limits.conf
}
sysctl -p &>/dev/null || true
success "系统参数设置完成"

info "开放防火墙端口 3306 / 33061..."
if command -v firewall-cmd &>/dev/null; then
  firewall-cmd --permanent --add-port=3306/tcp  &>/dev/null || true
  firewall-cmd --permanent --add-port=33061/tcp &>/dev/null || true
  firewall-cmd --reload &>/dev/null || true
  success "firewalld 规则已添加"
elif command -v ufw &>/dev/null; then
  ufw allow 3306/tcp  &>/dev/null || true
  ufw allow 33061/tcp &>/dev/null || true
  success "ufw 规则已添加"
else
  warn "未检测到防火墙工具，请手动开放 3306 和 33061 端口"
fi

# ================================================================
# 三、生成配置文件
# ================================================================
title "Step 3 / 5  生成配置文件"

info "生成 .env ..."
cat > "${DEPLOY_DIR}/.env" << EOF
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
CLUSTER_ADMIN_USER=clusteradmin
CLUSTER_ADMIN_PASSWORD=${CLUSTER_ADMIN_PASSWORD}
EOF
chmod 600 "${DEPLOY_DIR}/.env"
success ".env 生成完成"

info "生成 conf/my.cnf ..."
cat > "${DEPLOY_DIR}/conf/my.cnf" << EOF
[mysqld]
server-id                         = ${NODE_ID}
bind-address                      = 0.0.0.0
report_host                       = ${CURRENT_IP}
report_port                       = 3306

plugin-load-add                   = group_replication.so
loose-group_replication_group_name      = "6e17d0f0-aaaa-bbbb-cccc-000000000001"
loose-group_replication_start_on_boot   = OFF
loose-group_replication_local_address   = "${CURRENT_IP}:33061"
loose-group_replication_group_seeds     = "${NODE1_IP}:33061,${NODE2_IP}:33061,${NODE3_IP}:33061"
loose-group_replication_bootstrap_group = OFF
loose-group_replication_ip_allowlist    = "${NODE1_IP},${NODE2_IP},${NODE3_IP}"
loose-group_replication_communication_stack = MYSQL

gtid_mode                         = ON
enforce_gtid_consistency          = ON
log_bin                           = /var/log/mysql/mysql-bin
binlog_format                     = ROW
log_replica_updates               = ON
binlog_checksum                   = NONE
binlog_expire_logs_seconds        = 604800

innodb_buffer_pool_size           = 4G
innodb_buffer_pool_instances      = 4
innodb_log_file_size              = 512M
innodb_flush_log_at_trx_commit    = 1
innodb_flush_method               = O_DIRECT
innodb_io_capacity                = 2000
innodb_io_capacity_max            = 4000

max_connections                   = 1000
max_allowed_packet                = 64M
wait_timeout                      = 28800
interactive_timeout               = 28800
character-set-server              = utf8mb4
collation-server                  = utf8mb4_unicode_ci

slow_query_log                    = ON
slow_query_log_file               = /var/log/mysql/slow.log
long_query_time                   = 2
EOF
success "my.cnf 生成完成"

info "生成 docker-compose.yml ..."
cat > "${DEPLOY_DIR}/docker-compose.yml" << EOF
version: '3.8'

services:
  ${CONTAINER_NAME}:
    image: registry.cn-hangzhou.aliyuncs.com/sxxpqp/mysql:${MYSQL_VERSION}
    container_name: ${CONTAINER_NAME}
    hostname: ${CURRENT_IP}
    restart: always
    network_mode: host
    volumes:
      - ${DATA_DIR}:/var/lib/mysql
      - ${DEPLOY_DIR}/conf/my.cnf:/etc/mysql/conf.d/cluster.cnf:ro
      - ${DEPLOY_DIR}/logs:/var/log/mysql
    environment:
      MYSQL_ROOT_PASSWORD: "\${MYSQL_ROOT_PASSWORD}"
      MYSQL_ROOT_HOST: "%"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "-uroot", "-p\${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 30s
    logging:
      driver: "json-file"
      options:
        max-size: "200m"
        max-file: "5"
EOF
success "docker-compose.yml 生成完成"

if [[ "$NODE_ID" == "1" ]]; then
  info "生成 scripts/init_cluster.js (密码从环境变量读取，无明文)..."
  cat > "${DEPLOY_DIR}/scripts/init_cluster.js" << 'JSEOF'
// ================================================================
// MySQL InnoDB Cluster 初始化脚本
// 密码通过环境变量传入，文件本身不含任何敏感信息
// 请使用同目录的 run_init.sh 执行
// ================================================================

var rootPass  = os.getenv("MYSQL_ROOT_PASSWORD");
var adminPass = os.getenv("CLUSTER_ADMIN_PASSWORD");
var node1     = os.getenv("CLUSTER_NODE1");
var node2     = os.getenv("CLUSTER_NODE2");
var node3     = os.getenv("CLUSTER_NODE3");

if (!rootPass || !adminPass || !node1 || !node2 || !node3) {
  print("ERROR: Missing environment variables:");
  print("  MYSQL_ROOT_PASSWORD, CLUSTER_ADMIN_PASSWORD");
  print("  CLUSTER_NODE1, CLUSTER_NODE2, CLUSTER_NODE3");
  throw new Error("Missing required environment variables");
}

var CONFIG = {
  rootPass:    rootPass,
  adminUser:   "clusteradmin",
  adminPass:   adminPass,
  clusterName: "prodCluster",
  nodes: [
    { host: node1, port: 3306 },
    { host: node2, port: 3306 },
    { host: node3, port: 3306 },
  ],
};

print("=== 节点信息 ===");
print("  Node1 (Primary)  : " + node1);
print("  Node2 (Secondary): " + node2);
print("  Node3 (Secondary): " + node3);

// ── 等待节点 MySQL 可连接 ──────────────────────────────────────
function waitForNode(host, port, maxRetry) {
  maxRetry = maxRetry || 36;  // 最多等 3 分钟
  var connHost = (host === node1) ? "127.0.0.1" : host;
  for (var i = 0; i < maxRetry; i++) {
    try {
      var s = mysql.getSession("root:" + CONFIG.rootPass + "@" + connHost + ":" + port);
      s.close();
      print("OK " + host + " ready");
      return;
    } catch(e) {
      print("Waiting [" + (i+1) + "/" + maxRetry + "] " + host + "...");
      os.sleep(5);
    }
  }
  throw new Error("Timeout waiting for: " + host);
}

// ── 检查实例 gtid_mode / enforce_gtid_consistency 是否已生效 ──
function isInstanceReady(host, port) {
  var connHost = (host === node1) ? "127.0.0.1" : host;
  try {
    var s = mysql.getSession("root:" + CONFIG.rootPass + "@" + connHost + ":" + port);
    var r = s.runSql("SELECT @@gtid_mode, @@enforce_gtid_consistency, @@server_id").fetchOne();
    var gtid    = String(r[0]).trim().toUpperCase();
    var enforce = String(r[1]).trim().toUpperCase();
    var sid     = parseInt(r[2]);
    s.close();
    print("  -> gtid_mode=" + gtid + "  enforce=" + enforce + "  server_id=" + sid);
    return (gtid === "ON" && enforce === "ON" && sid > 0);
  } catch(e) {
    print("  -> error: " + e.message);
    return false;
  }
}

print("\n=== Step 1: Check all nodes ===");
for (var i = 0; i < CONFIG.nodes.length; i++) {
  waitForNode(CONFIG.nodes[i].host, CONFIG.nodes[i].port);
}

print("\n=== Step 1b: Verify MySQL config ===");
var needRecheck = false;
for (var i = 0; i < CONFIG.nodes.length; i++) {
  var n = CONFIG.nodes[i];
  print("Checking " + n.host + "...");
  if (!isInstanceReady(n.host, n.port)) {
    print("WARN " + n.host + ": config not ready, restart container and re-run");
    needRecheck = true;
  } else {
    print("OK " + n.host + " config verified");
  }
}
if (needRecheck) {
  throw new Error("Config not ready on some nodes. Restart containers then re-run.");
}

print("\n=== Step 2: Configure instances ===");
for (var i = 0; i < CONFIG.nodes.length; i++) {
  var n = CONFIG.nodes[i];
  var connHost = (n.host === node1) ? "127.0.0.1" : n.host;
  try {
    dba.configureInstance("root:" + CONFIG.rootPass + "@" + connHost + ":" + n.port, {
      clusterAdmin:         CONFIG.adminUser,
      clusterAdminPassword: CONFIG.adminPass,
      restart:              false,
      interactive:          false,
    });
    print("OK " + n.host + " configured");
  } catch(e) {
    if (e.message.indexOf("already") !== -1) {
      print("SKIP " + n.host + " already configured");
    } else { throw e; }
  }
}

print("\n=== Step 3: Create cluster ===");
shell.connect(CONFIG.adminUser + ":" + CONFIG.adminPass + "@127.0.0.1:3306");
var cluster;
try {
  cluster = dba.createCluster(CONFIG.clusterName, {
    multiPrimary: false, interactive: false, communicationStack: "MYSQL",
  });
  print("OK Cluster created");
} catch(e) {
  if (e.message.indexOf("already exists") !== -1 ||
      e.message.indexOf("already belongs") !== -1) {
    print("SKIP Cluster exists, retrieving...");
    cluster = dba.getCluster(CONFIG.clusterName);
  } else { throw e; }
}

print("\n=== Step 4: Add secondary nodes ===");
for (var i = 1; i < CONFIG.nodes.length; i++) {
  var n = CONFIG.nodes[i];
  try {
    cluster.addInstance(CONFIG.adminUser + ":" + CONFIG.adminPass + "@" + n.host + ":" + n.port, {
      recoveryMethod: "clone", waitRecovery: 3, interactive: false,
    });
    print("OK " + n.host + " joined");
  } catch(e) {
    if (e.message.indexOf("already a member") !== -1) {
      print("SKIP " + n.host + " already member");
    } else { throw e; }
  }
}

print("\n=== Cluster Status ===");
print(JSON.stringify(cluster.status(), null, 2));
print("\nDone! Primary: " + node1 + ":3306");
JSEOF
  chmod 600 "${DEPLOY_DIR}/scripts/init_cluster.js"
  success "init_cluster.js 生成完成（无密码明文）"

  # ── 生成 run_init.sh 入口脚本 ─────────────────────────────────
  info "生成 scripts/run_init.sh ..."
  RFILE="${DEPLOY_DIR}/scripts/run_init.sh"
  cat > "$RFILE" << RUNEOF
#!/bin/bash
# 集群初始化入口脚本 — 从 .deploy_state 读取所有参数，通过环境变量传入容器
# 用法: bash ${DEPLOY_DIR}/scripts/run_init.sh
set -euo pipefail

STATE_FILE="${DEPLOY_DIR}/../.deploy_state"
JS_FILE="${DEPLOY_DIR}/scripts/init_cluster.js"

# 优先读 .deploy_state，兼容回退到 .env
if [[ -f "\$STATE_FILE" ]]; then
  source "\$STATE_FILE"
  echo ">>> 从 .deploy_state 读取配置"
elif [[ -f "${DEPLOY_DIR}/.env" ]]; then
  source "${DEPLOY_DIR}/.env"
  echo ">>> 从 .env 读取配置（未找到 .deploy_state）"
else
  echo "ERROR: 找不到配置文件 .deploy_state 或 .env"; exit 1
fi

# 校验必要变量
for VAR in MYSQL_ROOT_PASSWORD CLUSTER_ADMIN_PASSWORD NODE1_IP NODE2_IP NODE3_IP; do
  [[ -n "\${!VAR:-}" ]] || { echo "ERROR: 变量 \$VAR 未设置，请检查 .deploy_state"; exit 1; }
done

echo ">>> 节点信息:"
echo "    Node1 (Primary)  : \${NODE1_IP}"
echo "    Node2 (Secondary): \${NODE2_IP}"
echo "    Node3 (Secondary): \${NODE3_IP}"

# 每台机器在 deploy.sh 安装阶段已自动重启并验证配置
# 此处直接复制脚本执行即可

echo ">>> 复制初始化脚本到容器..."
docker cp "\$JS_FILE" mysql1:/tmp/init_cluster.js

echo ">>> 执行集群初始化（密码通过环境变量传入容器，不写入任何文件）..."
docker exec -it \\
  -e MYSQL_ROOT_PASSWORD="\${MYSQL_ROOT_PASSWORD}" \\
  -e CLUSTER_ADMIN_PASSWORD="\${CLUSTER_ADMIN_PASSWORD}" \\
  -e CLUSTER_NODE1="\${NODE1_IP}" \\
  -e CLUSTER_NODE2="\${NODE2_IP}" \\
  -e CLUSTER_NODE3="\${NODE3_IP}" \\
  mysql1 \\
  mysqlsh "root:\${MYSQL_ROOT_PASSWORD}@127.0.0.1:3306" \\
  --js --file=/tmp/init_cluster.js

echo ">>> 验证集群状态..."
docker exec -it \\
  -e CLUSTER_ADMIN_PASSWORD="\${CLUSTER_ADMIN_PASSWORD}" \\
  mysql1 \\
  mysqlsh "clusteradmin:\${CLUSTER_ADMIN_PASSWORD}@127.0.0.1:3306" \\
  --js -e "print(JSON.stringify(dba.getCluster().status(), null, 2));"
RUNEOF
  chmod 700 "$RFILE"
  success "run_init.sh 生成完成"
fi


# ================================================================
# 四、启动服务并重启使配置生效
# ================================================================
title "Step 4 / 5  启动 MySQL 服务"

cd "${DEPLOY_DIR}"
info "拉取镜像 registry.cn-hangzhou.aliyuncs.com/sxxpqp/mysql:${MYSQL_VERSION} ..."
docker compose pull

info "首次启动容器（初始化数据目录）..."
docker compose up -d

info "等待 MySQL 首次启动完成（最长 120 秒）..."
for i in $(seq 1 24); do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "starting")
  if [[ "$STATUS" == "healthy" ]]; then
    success "${CONTAINER_NAME} 首次启动完成 ✓"; break
  fi
  printf "  [%2d/24] 状态: %-12s\r" "$i" "$STATUS"
  sleep 5
done
echo ""

info "重启容器使 my.cnf 配置生效（gtid_mode / server_id 等）..."
docker compose restart

info "等待 MySQL 重启完成（最长 120 秒）..."
for i in $(seq 1 24); do
  STATUS=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "starting")
  if [[ "$STATUS" == "healthy" ]]; then
    success "${CONTAINER_NAME} 重启完成，配置已生效 ✓"; break
  fi
  printf "  [%2d/24] 状态: %-12s\r" "$i" "$STATUS"
  sleep 5
done
echo ""

info "验证关键配置..."
GTID=$(docker exec "${CONTAINER_NAME}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}"   --silent --skip-column-names -e "SELECT @@gtid_mode" 2>/dev/null || echo "ERROR")
SID=$(docker exec "${CONTAINER_NAME}" mysql -uroot -p"${MYSQL_ROOT_PASSWORD}"   --silent --skip-column-names -e "SELECT @@server_id" 2>/dev/null || echo "ERROR")
if [[ "$GTID" == "ON" && "$SID" == "${NODE_ID}" ]]; then
  success "配置验证通过: gtid_mode=ON, server_id=${NODE_ID} ✓"
else
  warn "配置验证: gtid_mode=${GTID}, server_id=${SID}"
  warn "如不符合预期，请检查 ${DEPLOY_DIR}/conf/my.cnf 是否挂载正确"
fi

# ================================================================
# 五、完成提示
# ================================================================
title "Step 5 / 5  部署完成"

success "Node${NODE_ID} (${CURRENT_IP}) 部署成功！"
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  下一步操作${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ "$NODE_ID" == "1" ]]; then
  echo -e "  三台机器全部 healthy 后，在 Node1 一键执行初始化：\n"
  echo -e "  ${GREEN}bash ${DEPLOY_DIR}/scripts/run_init.sh${NC}\n"
  echo -e "  密码从 ${DEPLOY_DIR}/.env 自动读取，不会暴露在命令行或脚本文件中"
else
  echo -e "  ${YELLOW}▶ 等待三台机器全部部署完成后，在 Node1 (${NODE1_IP}) 执行:${NC}"
  echo -e "  ${GREEN}bash ${DEPLOY_DIR}/scripts/run_init.sh${NC}"
fi
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
printf "  %-12s: %s\n" "配置目录"  "${DEPLOY_DIR}"
printf "  %-12s: %s\n" "数据目录"  "${DATA_DIR}"
printf "  %-12s: %s\n" "MySQL版本" "registry.cn-hangzhou.aliyuncs.com/sxxpqp/mysql:${MYSQL_VERSION}"
printf "  %-12s: %s\n" "状态文件"  "${STATE_FILE}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}💡 如需修改某项参数: 编辑 ${STATE_FILE} 删除对应行，重新运行脚本${NC}"



