#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/docker-compose/rocketmq/deploy-back.sh
# =============================================================
# RocketMQ 5.3.2 三主三从 + Controller + Proxy 一键部署脚本
# 集群模式：3主3从  同步策略：SYNC_MASTER  Controller：启用
# 使用方式：
#   节点129执行：bash deploy.sh 0
#   节点130执行：bash deploy.sh 1
#   节点131执行：bash deploy.sh 2
# =============================================================

set -e

# -----------------------------------------------
# 基础配置（如需修改在此处调整）
# -----------------------------------------------
NODES=("172.16.150.129" "172.16.150.130" "172.16.150.131")
BROKER_NAMES=("broker-a" "broker-b" "broker-c")
IMAGE="apache/rocketmq:5.3.2"
BASE_DIR="/data/rocketmq"

JVM_NAMESRV="-Xms1g -Xmx1g"
JVM_BROKER_MASTER="-Xms8g -Xmx8g -XX:+UseG1GC -XX:G1HeapRegionSize=16m -XX:MaxGCPauseMillis=200"
JVM_BROKER_SLAVE="-Xms4g -Xmx4g -XX:+UseG1GC -XX:G1HeapRegionSize=16m"
JVM_PROXY="-Xms1g -Xmx1g"

# -----------------------------------------------
# 颜色输出
# -----------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BLUE}===== $* =====${NC}"; }

# -----------------------------------------------
# 参数校验
# -----------------------------------------------
NODE_INDEX=$1
if [[ -z "$NODE_INDEX" ]]; then
  echo -e "${YELLOW}用法：bash deploy.sh <节点序号>${NC}"
  echo "  bash deploy.sh 0   # 172.16.150.129"
  echo "  bash deploy.sh 1   # 172.16.150.130"
  echo "  bash deploy.sh 2   # 172.16.150.131"
  echo ""
  echo "其他命令："
  echo "  bash deploy.sh status   # 查看集群状态"
  echo "  bash deploy.sh stop     # 停止当前节点所有容器"
  echo "  bash deploy.sh restart  # 重启当前节点所有容器"
  echo "  bash deploy.sh verify   # 验证集群（在任意节点执行）"
  exit 0
fi

# -----------------------------------------------
# 特殊命令处理
# -----------------------------------------------
handle_special_cmd() {
  local cmd=$1
  case $cmd in
    status)
      info "当前节点容器状态："
      docker compose -f ${BASE_DIR}/docker-compose.yml ps 2>/dev/null || docker ps --filter "name=rmq"
      exit 0
      ;;
    stop)
      info "停止当前节点所有 RocketMQ 容器..."
      docker compose -f ${BASE_DIR}/docker-compose.yml down
      success "已停止"
      exit 0
      ;;
    restart)
      info "重启当前节点所有 RocketMQ 容器..."
      docker compose -f ${BASE_DIR}/docker-compose.yml restart
      success "已重启"
      exit 0
      ;;
    verify)
      verify_cluster
      exit 0
      ;;
  esac
}

if [[ "$NODE_INDEX" =~ ^(status|stop|restart|verify)$ ]]; then
  handle_special_cmd "$NODE_INDEX"
fi

if [[ "$NODE_INDEX" != "0" && "$NODE_INDEX" != "1" && "$NODE_INDEX" != "2" ]]; then
  error "节点序号必须是 0、1 或 2"
fi

# -----------------------------------------------
# 派生变量
# -----------------------------------------------
SELF_IP="${NODES[$NODE_INDEX]}"
SELF_ID="n${NODE_INDEX}"

# 主 Broker：本节点自己
MASTER_NAME="${BROKER_NAMES[$NODE_INDEX]}"

# 从 Broker：备份上一个节点的数据（错位分布）
# 129备份131的c，130备份129的a，131备份130的b
SLAVE_INDEX=$(( (NODE_INDEX + 2) % 3 ))
SLAVE_NAME="${BROKER_NAMES[$SLAVE_INDEX]}"

# NameServer 地址串
NAMESRV_ADDR="${NODES[0]}:9876;${NODES[1]}:9876;${NODES[2]}:9876"
CONTROLLER_ADDR="${NODES[0]}:9877;${NODES[1]}:9877;${NODES[2]}:9877"
DLEDGER_PEERS="n0-${NODES[0]}:9878;n1-${NODES[1]}:9878;n2-${NODES[2]}:9878"

# -----------------------------------------------
# 环境检查
# -----------------------------------------------
check_env() {
  step "环境检查"
  command -v docker &>/dev/null || error "docker 未安装"
  docker compose version &>/dev/null || error "docker compose 未安装"
  success "docker 环境正常"

  # 检查内存
  local mem_gb
  mem_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo)
  if [[ $mem_gb -lt 20 ]]; then
    warn "内存 ${mem_gb}GB，Broker Master JVM 设置为 8g，请确认是否充足"
  else
    success "内存 ${mem_gb}GB，满足要求"
  fi

  # 检查端口
  local ports=(9876 9877 9878 10911 10921 8080 8081)
  for port in "${ports[@]}"; do
    if ss -tlnp | grep -q ":${port} "; then
      warn "端口 ${port} 已被占用，请检查"
    fi
  done
  success "端口检查完成"
}

# -----------------------------------------------
# 创建目录
# -----------------------------------------------
create_dirs() {
  step "创建目录结构"
  local dirs=(
    "${BASE_DIR}/conf"
    "${BASE_DIR}/logs/namesrv"
    "${BASE_DIR}/logs/broker-master"
    "${BASE_DIR}/logs/broker-slave"
    "${BASE_DIR}/store/master/commitlog"
    "${BASE_DIR}/store/master/consumequeue"
    "${BASE_DIR}/store/master/index"
    "${BASE_DIR}/store/slave/commitlog"
    "${BASE_DIR}/store/slave/consumequeue"
    "${BASE_DIR}/store/slave/index"
  )
  for d in "${dirs[@]}"; do
    mkdir -p "$d"
  done
  success "目录创建完成：${BASE_DIR}"
}

# -----------------------------------------------
# 生成 namesrv.conf
# -----------------------------------------------
gen_namesrv_conf() {
  step "生成 namesrv.conf（节点 ${SELF_ID}）"
  cat > "${BASE_DIR}/conf/namesrv.conf" <<EOF
# NameServer + Controller 配置
# 节点：${SELF_IP} (${SELF_ID})
enableControllerInNamesrv=true
controllerDLegerGroup=dledger-controller
controllerDLegerPeers=${DLEDGER_PEERS}
controllerDLegerSelfId=${SELF_ID}
controllerStorePath=/home/rocketmq/logs/namesrv/controller
EOF
  success "namesrv.conf 生成完成"
}

# -----------------------------------------------
# 生成 broker-master.conf
# -----------------------------------------------
gen_broker_master_conf() {
  step "生成 broker-master.conf（${MASTER_NAME} @ ${SELF_IP}:10911）"
  cat > "${BASE_DIR}/conf/broker-master.conf" <<EOF
# Broker Master 配置
# 节点：${SELF_IP}，brokerName：${MASTER_NAME}
brokerClusterName=DefaultCluster
brokerName=${MASTER_NAME}
listenPort=10911

# Controller 自动选主
enableControllerMode=true
controllerAddr=${CONTROLLER_ADDR}

# 初始均为 SLAVE，Controller 选出 Master 后自动切换
brokerRole=SLAVE
flushDiskType=SYNC_FLUSH

# 存储路径
storePathRootDir=/home/rocketmq/store/master
storePathCommitLog=/home/rocketmq/store/master/commitlog
storePathConsumerQueue=/home/rocketmq/store/master/consumequeue
storePathIndex=/home/rocketmq/store/master/index
storeCheckpoint=/home/rocketmq/store/master/checkpoint

# Topic 管理（禁止自动创建，防止 topic 丢失）
autoCreateTopicEnable=false
autoCreateSubscriptionGroup=false

# 磁盘保留策略
fileReservedTime=72
deleteWhen=04
diskSpaceCleanForciblyRatio=0.85
diskSpaceWarningLevelRatio=0.90

# 性能参数
sendMessageThreadPoolNums=128
pullMessageThreadPoolNums=128
EOF
  success "broker-master.conf 生成完成"
}

# -----------------------------------------------
# 生成 broker-slave.conf
# -----------------------------------------------
gen_broker_slave_conf() {
  step "生成 broker-slave.conf（${SLAVE_NAME} Slave @ ${SELF_IP}:10921）"
  cat > "${BASE_DIR}/conf/broker-slave.conf" <<EOF
# Broker Slave 配置
# 节点：${SELF_IP}，备份 ${SLAVE_NAME} 的数据
brokerClusterName=DefaultCluster
brokerName=${SLAVE_NAME}
listenPort=10921

# Controller 自动选主
enableControllerMode=true
controllerAddr=${CONTROLLER_ADDR}

brokerRole=SLAVE
flushDiskType=SYNC_FLUSH

# 存储路径
storePathRootDir=/home/rocketmq/store/slave
storePathCommitLog=/home/rocketmq/store/slave/commitlog
storePathConsumerQueue=/home/rocketmq/store/slave/consumequeue
storePathIndex=/home/rocketmq/store/slave/index
storeCheckpoint=/home/rocketmq/store/slave/checkpoint

# Topic 管理
autoCreateTopicEnable=false
autoCreateSubscriptionGroup=false

# 磁盘保留策略
fileReservedTime=72
deleteWhen=04
diskSpaceCleanForciblyRatio=0.85
diskSpaceWarningLevelRatio=0.90
EOF
  success "broker-slave.conf 生成完成"
}

# -----------------------------------------------
# 生成 docker-compose.yml
# -----------------------------------------------
gen_compose() {
  step "生成 docker-compose.yml"
  cat > "${BASE_DIR}/docker-compose.yml" <<EOF
# RocketMQ 5.3.2 三主三从 + Controller + Proxy
# 节点：${SELF_IP} (index=${NODE_INDEX})
# Master：${MASTER_NAME}  Slave：${SLAVE_NAME}

services:
  namesrv:
    image: ${IMAGE}
    container_name: rmqnamesrv
    restart: always
    network_mode: host
    environment:
      - JAVA_OPT=${JVM_NAMESRV}
    volumes:
      - ${BASE_DIR}/logs/namesrv:/home/rocketmq/logs/namesrv
      - ${BASE_DIR}/conf/namesrv.conf:/home/rocketmq/rocketmq-5.3.2/conf/namesrv.conf
    command: sh mqnamesrv -c /home/rocketmq/rocketmq-5.3.2/conf/namesrv.conf
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://127.0.0.1:9876 || exit 0"]
      interval: 15s
      timeout: 5s
      retries: 5

  broker-master:
    image: ${IMAGE}
    container_name: rmqbroker-master
    restart: always
    network_mode: host
    depends_on:
      namesrv:
        condition: service_started
    environment:
      - NAMESRV_ADDR=${NAMESRV_ADDR}
      - JAVA_OPT=${JVM_BROKER_MASTER}
    volumes:
      - ${BASE_DIR}/logs/broker-master:/home/rocketmq/logs
      - ${BASE_DIR}/store/master:/home/rocketmq/store/master
      - ${BASE_DIR}/conf/broker-master.conf:/home/rocketmq/rocketmq-5.3.2/conf/broker-master.conf
    command: sh mqbroker -c /home/rocketmq/rocketmq-5.3.2/conf/broker-master.conf

  broker-slave:
    image: ${IMAGE}
    container_name: rmqbroker-slave
    restart: always
    network_mode: host
    depends_on:
      namesrv:
        condition: service_started
    environment:
      - NAMESRV_ADDR=${NAMESRV_ADDR}
      - JAVA_OPT=${JVM_BROKER_SLAVE}
    volumes:
      - ${BASE_DIR}/logs/broker-slave:/home/rocketmq/logs
      - ${BASE_DIR}/store/slave:/home/rocketmq/store/slave
      - ${BASE_DIR}/conf/broker-slave.conf:/home/rocketmq/rocketmq-5.3.2/conf/broker-slave.conf
    command: sh mqbroker -c /home/rocketmq/rocketmq-5.3.2/conf/broker-slave.conf

  proxy:
    image: ${IMAGE}
    container_name: rmqproxy
    restart: always
    network_mode: host
    depends_on:
      - broker-master
    environment:
      - NAMESRV_ADDR=${NAMESRV_ADDR}
      - JAVA_OPT=${JVM_PROXY}
    command: sh mqproxy -n "${NAMESRV_ADDR}"
EOF
  success "docker-compose.yml 生成完成"
}

# -----------------------------------------------
# 拉取镜像
# -----------------------------------------------
pull_image() {
  step "拉取镜像 ${IMAGE}"
  docker pull ${IMAGE}
  success "镜像拉取完成"
}

# -----------------------------------------------
# 启动服务
# -----------------------------------------------
start_services() {
  step "启动服务"
  cd "${BASE_DIR}"

  info "启动 NameServer..."
  docker compose up -d namesrv
  info "等待 NameServer 就绪（15s）..."
  sleep 15

  info "启动 Broker Master & Slave..."
  docker compose up -d broker-master broker-slave
  info "等待 Broker 注册（10s）..."
  sleep 10

  info "启动 Proxy..."
  docker compose up -d proxy

  success "所有服务已启动"
}

# -----------------------------------------------
# 验证集群
# -----------------------------------------------
verify_cluster() {
  step "验证集群状态"
  local ns="${NODES[0]}:9876"

  info "查看集群节点列表："
  docker exec rmqnamesrv sh mqadmin clusterList \
    -n "${NODES[0]}:9876;${NODES[1]}:9876;${NODES[2]}:9876" 2>/dev/null || \
    warn "clusterList 查询失败，请稍后重试"

  echo ""
  info "查看 Controller 同步状态："
  docker exec rmqnamesrv sh mqadmin getSyncStateSet \
    -a "${NODES[0]}:9877" \
    -n "$ns" 2>/dev/null || \
    warn "getSyncStateSet 查询失败"

  echo ""
  info "容器运行状态："
  docker ps --filter "name=rmq" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
}

# -----------------------------------------------
# 打印部署摘要
# -----------------------------------------------
print_summary() {
  echo ""
  echo -e "${GREEN}=============================================${NC}"
  echo -e "${GREEN}  RocketMQ 部署完成${NC}"
  echo -e "${GREEN}=============================================${NC}"
  echo -e "  当前节点  : ${SELF_IP} (index=${NODE_INDEX})"
  echo -e "  Master    : ${MASTER_NAME} → ${SELF_IP}:10911"
  echo -e "  Slave     : ${SLAVE_NAME} → ${SELF_IP}:10921"
  echo ""
  echo -e "  主从分布（三台整体）："
  echo -e "    129  broker-a Master + broker-c Slave"
  echo -e "    130  broker-b Master + broker-a Slave"
  echo -e "    131  broker-c Master + broker-b Slave"
  echo ""
  echo -e "  端口说明："
  echo -e "    9876  NameServer"
  echo -e "    9877  Controller 服务"
  echo -e "    9878  Controller Raft 选举"
  echo -e "    10911 Broker Master"
  echo -e "    10921 Broker Slave"
  echo -e "    8080  Proxy HTTP"
  echo -e "    8081  Proxy gRPC"
  echo ""
  echo -e "  常用命令："
  echo -e "    bash deploy.sh verify   # 验证集群"
  echo -e "    bash deploy.sh status   # 查看容器状态"
  echo -e "    bash deploy.sh stop     # 停止所有容器"
  echo -e "    bash deploy.sh restart  # 重启所有容器"
  echo ""
  echo -e "  手动创建 Topic："
  echo -e "    docker exec rmqnamesrv sh mqadmin updateTopic \\"
  echo -e "      -n \"${NAMESRV_ADDR}\" \\"
  echo -e "      -c DefaultCluster -t <topic-name> -w 6 -r 6"
  echo -e "${GREEN}=============================================${NC}"
}

# -----------------------------------------------
# 主流程
# -----------------------------------------------
main() {
  echo -e "${BLUE}"
  echo "  ____            _        _   __  __  ___  "
  echo " |  _ \ ___   ___| | _____| |_|  \/  |/ _ \ "
  echo " | |_) / _ \ / __| |/ / _ \ __| |\/| | | | |"
  echo " |  _ < (_) | (__|   <  __/ |_| |  | | |_| |"
  echo " |_| \_\___/ \___|_|\_\___|\__|_|  |_|\__\_\\"
  echo -e "${NC}"
  echo -e "  节点 ${NODE_INDEX}：${SELF_IP}   Master:${MASTER_NAME}  Slave:${SLAVE_NAME}"
  echo ""

  check_env
  create_dirs
  gen_namesrv_conf
  gen_broker_master_conf
  gen_broker_slave_conf
  gen_compose
  pull_image
  start_services
  sleep 5
  verify_cluster
  print_summary
}

main



