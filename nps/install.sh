#!/bin/bash
# 系统: Linux (systemd)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/nps/install.sh
# 用法: curl -sL <URL> | bash -s [server|client|all|uninstall]
#
# nps/npc Docker 安装脚本
# 通过 .env 文件配置所有变量。
# 支持 server（服务端）、client（客户端）、all（全装）、uninstall（卸载）。

set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

# ============================================================
# 颜色
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*" >&2; }
step()  { echo -e "${CYAN}[$1/$TOTAL]${NC} $2"; }

# ============================================================
# 默认值（.env 加载后可覆盖）
# ============================================================
INSTALL_MODE=server
NPS_IMAGE="registry.cn-hangzhou.aliyuncs.com/sxxpqp/nps"
NPC_IMAGE="registry.cn-hangzhou.aliyuncs.com/sxxpqp/npc"

NPS_CONF_DIR="/opt/nps/conf"
NPS_BRIDGE_PORT=8024
NPS_HTTP_PORT=80
NPS_HTTPS_PORT=443
NPS_WEB_PORT=8080
NPS_WEB_USERNAME=admin
NPS_WEB_PASSWORD=123
NPS_PUBLIC_VKEY=123
NPS_AUTH_CRYPT_KEY=1234567812345678

NPC_SERVER="192.168.1.1:8024"
NPC_VKEY="your_vkey_here"
NPC_TYPE=tcp

# ============================================================
# 加载 .env
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

load_env() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$ENV_FILE"; set +a
    info "已加载 $ENV_FILE"
  else
    warn "未找到 $ENV_FILE，使用默认值。建议 cp .env.example .env 后修改"
  fi
}

# ============================================================
# 前置检查
# ============================================================
check_prereqs() {
  local missing=0

  if ! command -v docker &>/dev/null; then
    err "Docker 未安装，请先安装 Docker"
    err "快速安装: curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun"
    missing=1
  fi

  if ! docker info &>/dev/null; then
    err "Docker 守护进程未运行或当前用户不在 docker 组"
    err "修复: sudo usermod -aG docker \$USER && newgrp docker"
    missing=1
  fi

  # 检查端口占用（服务端模式时）
  if [[ "$INSTALL_MODE" == "server" || "$INSTALL_MODE" == "all" ]]; then
    for port in "$NPS_BRIDGE_PORT" "$NPS_HTTP_PORT" "$NPS_WEB_PORT"; do
      if ss -tlnp "sport = :$port" 2>/dev/null | grep -q LISTEN; then
        warn "端口 $port 已被占用，请修改 .env 中对应配置"
      fi
    done
  fi

  if [ "$missing" -ne 0 ]; then
    exit 1
  fi
}

# ============================================================
# nps 服务端安装
# ============================================================
install_server() {
  info "===== 安装 nps 服务端 ====="

  # 创建配置目录
  mkdir -p "$NPS_CONF_DIR"

  # 生成 nps.conf（如不存在则创建）
  local CONF_FILE="${NPS_CONF_DIR}/nps.conf"
  if [ -f "$CONF_FILE" ]; then
    warn "$CONF_FILE 已存在，跳过生成"
  else
    info "生成 $CONF_FILE"
    cat > "$CONF_FILE" <<EOF
appname = nps
runmode = dev

http_proxy_ip=0.0.0.0
http_proxy_port=${NPS_HTTP_PORT}
https_proxy_port=${NPS_HTTPS_PORT}
https_just_proxy=true
https_default_cert_file=conf/server.pem
https_default_key_file=conf/server.key

bridge_type=tcp
bridge_port=${NPS_BRIDGE_PORT}
bridge_ip=0.0.0.0

public_vkey=${NPS_PUBLIC_VKEY}

log_level=7

web_host=a.o.com
web_username=${NPS_WEB_USERNAME}
web_password=${NPS_WEB_PASSWORD}
web_port=${NPS_WEB_PORT}
web_ip=0.0.0.0
web_base_url=
web_open_ssl=false
web_cert_file=conf/server.pem
web_key_file=conf/server.key

auth_crypt_key =${NPS_AUTH_CRYPT_KEY}

allow_user_login=false
allow_user_register=false
allow_user_change_username=false

allow_flow_limit=false
allow_rate_limit=false
allow_tunnel_num_limit=false
allow_local_proxy=false
allow_connection_num_limit=false
allow_multi_ip=false
system_info_display=false

http_cache=false
http_cache_length=100

http_add_origin_header=false

disconnect_timeout=60
EOF
  fi

  # 初始化 json 文件
  for f in clients.json tasks.json hosts.json; do
    local fpath="${NPS_CONF_DIR}/$f"
    if [ ! -f "$fpath" ]; then
      echo '{}' > "$fpath"
      info "初始化 $fpath"
    fi
  done

  # 拉取镜像
  info "拉取镜像 $NPS_IMAGE"
  docker pull "$NPS_IMAGE"

  # 停止并删除旧容器
  docker rm -f nps 2>/dev/null || true

  # 启动容器
  info "启动 nps 容器 (bridge=$NPS_BRIDGE_PORT web=$NPS_WEB_PORT)"
  docker run -d \
    --name=nps \
    --restart=always \
    --privileged \
    --net=host \
    -v "${NPS_CONF_DIR}:/conf" \
    "$NPS_IMAGE"

  echo ""
  info "nps 服务端启动完成！"
  info "管理界面: http://<IP>:${NPS_WEB_PORT}"
  info "用户名:    ${NPS_WEB_USERNAME}"
  info "密码:      ${NPS_WEB_PASSWORD}"
  info "客户端连接: -server=<IP>:${NPS_BRIDGE_PORT} -vkey=${NPS_PUBLIC_VKEY}"
}

# ============================================================
# npc 客户端安装
# ============================================================
install_client() {
  info "===== 安装 npc 客户端 ====="

  if [ "$NPC_VKEY" = "your_vkey_here" ]; then
    err "NPC_VKEY 未配置！请修改 .env 中的 NPC_VKEY"
    err "在 nps 管理界面 -> 客户端 -> 添加 -> 获取 vkey"
    exit 1
  fi

  # 拉取镜像
  info "拉取镜像 $NPC_IMAGE"
  docker pull "$NPC_IMAGE"

  # 停止并删除旧容器
  docker rm -f npc 2>/dev/null || true

  # 启动容器
  info "启动 npc 容器 (server=$NPC_SERVER)"
  docker run -d \
    --name=npc \
    --restart=always \
    --privileged \
    --net=host \
    "$NPC_IMAGE" \
    -server="${NPC_SERVER}" -vkey="${NPC_VKEY}" -type="${NPC_TYPE}"

  echo ""
  info "npc 客户端启动完成！"
  info "连接服务端: ${NPC_SERVER}"
  docker logs npc 2>&1 | tail -5
}

# ============================================================
# 卸载
# ============================================================
uninstall_all() {
  info "===== 卸载 nps/npc ====="

  for c in nps npc; do
    if docker ps -a --format '{{.Names}}' | grep -q "^$c$"; then
      docker rm -f "$c"
      info "已删除容器 $c"
    else
      info "容器 $c 不存在，跳过"
    fi
  done

  info "卸载完成"
  warn "配置目录 ${NPS_CONF_DIR} 保留未删，如需清理请手动 rm -rf ${NPS_CONF_DIR}"
}

# ============================================================
# 主流程
# ============================================================
TOTAL=5
main() {
  # ── 解析 CLI 参数 ──
  local cmd="${1:-}"
  [[ -n "$cmd" ]] && INSTALL_MODE="$cmd"

  load_env

  # 卸载模式
  if [[ "$INSTALL_MODE" == "uninstall" ]]; then
    uninstall_all
    exit 0
  fi

  # 校验安装模式
  case "$INSTALL_MODE" in
    server|client|all) ;;
    *)
      err "未知模式: $INSTALL_MODE"
      echo "用法: $0 [server|client|all|uninstall]"
      echo "  未指定参数时默认读取 .env 中的 INSTALL_MODE"
      exit 1
      ;;
  esac

  echo ""
  info "安装模式: $INSTALL_MODE"
  echo ""

  step 1 "前置检查" && check_prereqs
  step 2 "环境检查" && info "Docker $(docker --version)"

  # ── 拉镜像 ──
  step 3 "拉取镜像"
  case "$INSTALL_MODE" in
    server) docker pull "$NPS_IMAGE" ;;
    client) docker pull "$NPC_IMAGE" ;;
    all)    docker pull "$NPS_IMAGE" && docker pull "$NPC_IMAGE" ;;
  esac
  info "镜像就绪"

  # ── 部署 ──
  step 4 "部署容器"
  case "$INSTALL_MODE" in
    server) install_server ;;
    client) install_client ;;
    all)    install_server; echo ""; install_client ;;
  esac

  # ── 验证 ──
  step 5 "验证"
  case "$INSTALL_MODE" in
    server|all)
      if docker ps --format '{{.Names}}' | grep -q "^nps$"; then
        info "nps  ✓ 运行中"
      else
        err "nps  ✗ 未运行"
      fi
      ;;
  esac
  case "$INSTALL_MODE" in
    client|all)
      if docker ps --format '{{.Names}}' | grep -q "^npc$"; then
        info "npc  ✓ 运行中"
      else
        err "npc  ✗ 未运行"
      fi
      ;;
  esac

  echo ""
  info "安装完成！"
}

main "$@"
