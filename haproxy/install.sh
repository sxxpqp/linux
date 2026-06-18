#!/usr/bin/env bash
# 系统: HAProxy L4 TCP 模式代理 ingress-nginx(80/443 TLS 透传)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/haproxy/install.sh
# 用法: bash install.sh --ingress-nodes=192.168.150.242,192.168.150.243 [选项]
#
# 部署建议:
#   - HAProxy 跑在独立边缘节点(VM / 物理机均可),不要跟 ingress-nginx 同机
#   - 高可用需求:再装一台 + Keepalived 拉 VIP(本脚本不带 keepalived,见 README.md)
#   - 客户端真实 IP 需求:见配置末尾的 PROXY protocol 启用步骤

set -euo pipefail

INGRESS_NODES=""
HTTP_PORT="80"
HTTPS_PORT="443"
STATS_PORT="8404"
STATS_PASSWD=""
NBTHREAD=""              # 空 = 取 nproc(默认 = CPU 核数)
SERVER_MAXCONN="5000"    # 每个后端 server 的并发连接上限
DRY_RUN="false"

usage() {
  cat <<'EOF'
用法: bash install.sh --ingress-nodes=IP1,IP2[,...] [选项]

必填:
  --ingress-nodes=IPs       后端 ingress-nginx 节点 IP 列表,逗号分隔
                            例: --ingress-nodes=192.168.150.242,192.168.150.243

可选:
  --http-port=N             HAProxy 监听 HTTP 端口,默认 80
  --https-port=N            HAProxy 监听 HTTPS 端口,默认 443
  --stats-port=N            stats UI 监听端口,默认 8404
  --stats-passwd=XXX        stats UI 登录密码,默认随机生成 16 位
  --nbthread=N              HAProxy 工作线程数,默认 = nproc(CPU 核数)
  --server-maxconn=N        每个后端 server 的并发连接上限,默认 5000
  --dry-run                 只生成 /etc/haproxy/haproxy.cfg,不重启服务
  -h, --help                显示帮助

示例:
  # 最简:两台 ingress
  bash install.sh --ingress-nodes=192.168.150.242,192.168.150.243

  # 三台 + 自定义密码
  bash install.sh --ingress-nodes=10.0.0.1,10.0.0.2,10.0.0.3 --stats-passwd='Adm!n123'

  # 只生成配置看一眼
  bash install.sh --ingress-nodes=10.0.0.1,10.0.0.2 --dry-run
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ingress-nodes=*) INGRESS_NODES="${1#*=}" ;;
    --http-port=*)     HTTP_PORT="${1#*=}" ;;
    --https-port=*)    HTTPS_PORT="${1#*=}" ;;
    --stats-port=*)    STATS_PORT="${1#*=}" ;;
    --stats-passwd=*)  STATS_PASSWD="${1#*=}" ;;
    --nbthread=*)      NBTHREAD="${1#*=}" ;;
    --server-maxconn=*) SERVER_MAXCONN="${1#*=}" ;;
    --dry-run)         DRY_RUN="true" ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/haproxy.cfg.tpl"
TARGET_CFG="/etc/haproxy/haproxy.cfg"

# ============================================================
# 1/5 前置检查
# ============================================================
log "[1/5] 前置检查"

if [ -z "$INGRESS_NODES" ]; then
  err "必须用 --ingress-nodes 指定后端节点 IP,例: --ingress-nodes=10.0.0.1,10.0.0.2"
  exit 1
fi

if [ ! -f "$TEMPLATE" ]; then
  err "配置模板不在脚本同目录: $TEMPLATE"
  exit 1
fi
ok "模板: $TEMPLATE"

if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" != "true" ]; then
  err "需 root 权限执行,sudo bash install.sh ..."
  exit 1
fi

# 解析后端节点 IP
IFS=',' read -ra NODES <<< "$INGRESS_NODES"
if [ "${#NODES[@]}" -lt 1 ]; then
  err "至少需要 1 个 ingress 节点"
  exit 1
fi
ok "后端 ingress 节点: ${NODES[*]} (共 ${#NODES[@]} 台)"

# 测试每个节点的 80/443 是否通(不通也继续,只 warn)
for ip in "${NODES[@]}"; do
  for port in "$HTTP_PORT" "$HTTPS_PORT"; do
    if timeout 3 bash -c "</dev/tcp/$ip/$port" 2>/dev/null; then
      ok "  $ip:$port 可达"
    else
      warn "  $ip:$port 不通(ingress-nginx 没起或防火墙挡了 — HAProxy 仍会装,后端 DOWN 时不发流量)"
    fi
  done
done

# 随机密码 —— 不能用 `tr ... | head -c N` 这种写法,
# head 读够就关管道,tr 再写会被 SIGPIPE 杀掉(退出 141),
# set -o pipefail 下会被当成 pipeline 失败,脚本静默退出
if [ -z "$STATS_PASSWD" ]; then
  if command -v openssl >/dev/null 2>&1; then
    STATS_PASSWD=$(openssl rand -hex 8)
  else
    # 纯 bash 后备:先 base64 拿到固定长度字符串,再做过滤
    RAW=$(head -c 64 /dev/urandom | base64)
    RAW="${RAW//[^A-Za-z0-9]/}"
    STATS_PASSWD="${RAW:0:16}"
  fi
  ok "stats UI 密码自动生成: $STATS_PASSWD"
else
  ok "stats UI 密码已指定"
fi

# ============================================================
# 2/5 安装 haproxy 包
# ============================================================
log "[2/5] 安装 haproxy"

if command -v haproxy >/dev/null 2>&1; then
  VER=$(haproxy -v 2>&1 | head -1)
  ok "已安装: $VER"
else
  if [ "$DRY_RUN" = "true" ]; then
    warn "[dry-run] 会安装 haproxy"
  elif command -v apt-get >/dev/null 2>&1; then
    log "  apt 安装 haproxy ..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy
  elif command -v yum >/dev/null 2>&1; then
    log "  yum 安装 haproxy ..."
    yum install -y haproxy
  elif command -v dnf >/dev/null 2>&1; then
    log "  dnf 安装 haproxy ..."
    dnf install -y haproxy
  else
    err "未识别的包管理器,手动装 haproxy 后重跑"
    exit 1
  fi
  ok "haproxy 已安装: $(haproxy -v 2>&1 | head -1)"
fi

# ============================================================
# 3/5 生成 /etc/haproxy/haproxy.cfg
# ============================================================
log "[3/5] 生成配置 $TARGET_CFG"

# 默认 nbthread = CPU 核数;命令行 --nbthread 优先
if [ -z "$NBTHREAD" ]; then
  NBTHREAD=$(nproc 2>/dev/null || echo 4)
fi
ok "nbthread = $NBTHREAD  / server maxconn = $SERVER_MAXCONN"

# 构造 server 行(带 maxconn,均匀压力上限)
SERVERS_HTTP=""
SERVERS_HTTPS=""
i=1
for ip in "${NODES[@]}"; do
  SERVERS_HTTP+="    server ingress${i} ${ip}:${HTTP_PORT}  check inter 2s fall 3 rise 2 maxconn ${SERVER_MAXCONN}"$'\n'
  SERVERS_HTTPS+="    server ingress${i} ${ip}:${HTTPS_PORT} check inter 2s fall 3 rise 2 maxconn ${SERVER_MAXCONN}"$'\n'
  i=$((i+1))
done
# 去掉末尾换行,避免渲染时多一行空行
SERVERS_HTTP="${SERVERS_HTTP%$'\n'}"
SERVERS_HTTPS="${SERVERS_HTTPS%$'\n'}"

# 备份现有配置
if [ -f "$TARGET_CFG" ] && [ "$DRY_RUN" != "true" ]; then
  BAK="${TARGET_CFG}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "$TARGET_CFG" "$BAK"
  ok "已备份旧配置: $BAK"
fi

# 用 awk 做模板替换,纯 POSIX 工具,避免依赖 python3
# 关键防护:注释行(可前置空格)原样输出,跳过 gsub —— 否则模板自己的
# 注释里如果提到占位符名字(说明文档),也会被一起替换,生成的 cfg
# 会出现游离的 server 行,触发 haproxy "unknown keyword out of section"
TMP_OUT=$(mktemp)
awk -v http="$SERVERS_HTTP" \
    -v https="$SERVERS_HTTPS" \
    -v pw="$STATS_PASSWD" \
    -v sp="$STATS_PORT" \
    -v nt="$NBTHREAD" '
{
  if ($0 ~ /^[[:space:]]*#/) { print; next }    # 注释行原样输出
  gsub(/__HTTP_BACKENDS__/,  http)
  gsub(/__HTTPS_BACKENDS__/, https)
  gsub(/__NBTHREAD__/,       nt)
  gsub(/STATS_PASSWD/,       pw)
  gsub(/:8404/,              ":" sp)
  print
}' "$TEMPLATE" > "$TMP_OUT"

if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] 生成的配置(不写入):"
  cat "$TMP_OUT"
  rm -f "$TMP_OUT"
  exit 0
fi

mkdir -p "$(dirname "$TARGET_CFG")"
mv "$TMP_OUT" "$TARGET_CFG"
chmod 644 "$TARGET_CFG"
ok "$TARGET_CFG 已写入"

# 语法检查
log "  haproxy -c 语法检查..."
if haproxy -c -f "$TARGET_CFG" >/dev/null 2>&1; then
  ok "配置语法 OK"
else
  err "配置语法错误,详细输出:"
  haproxy -c -f "$TARGET_CFG" || true
  exit 1
fi

# ============================================================
# 4/5 启用 + 启动 systemd 服务
# ============================================================
log "[4/5] 启动 haproxy"

systemctl enable haproxy >/dev/null 2>&1 || true
if systemctl is-active haproxy >/dev/null 2>&1; then
  log "  reload haproxy(已运行)..."
  systemctl reload haproxy || systemctl restart haproxy
else
  log "  start haproxy..."
  systemctl start haproxy
fi

sleep 1
if systemctl is-active haproxy >/dev/null 2>&1; then
  ok "haproxy 服务运行中"
else
  err "haproxy 启动失败,journalctl -u haproxy --no-pager -n 50:"
  journalctl -u haproxy --no-pager -n 50 || true
  exit 1
fi

# ============================================================
# 5/5 验证
# ============================================================
log "[5/5] 验证"

HOST_IP=$(hostname -I | awk '{print $1}')
ok "本机 IP: $HOST_IP"
ok "已开放端口:"
ok "  HTTP   → $HOST_IP:$HTTP_PORT  →  ingress-nginx 80"
ok "  HTTPS  → $HOST_IP:$HTTPS_PORT →  ingress-nginx 443 (TLS 透传)"
ok "  Stats  → http://$HOST_IP:$STATS_PORT/stats  (admin / $STATS_PASSWD)"

echo
log "==== 安装完成 ===="
echo
echo "测试:"
echo "  curl -sI http://$HOST_IP:$HTTP_PORT  -H 'Host: test-dsp.wishfoxs.com'"
echo "  curl -skI https://$HOST_IP:$HTTPS_PORT -H 'Host: test-dsp.wishfoxs.com'"
echo
echo "Stats:浏览器开 http://$HOST_IP:$STATS_PORT/stats"
echo "      用户名 admin   密码 $STATS_PASSWD"
echo
echo "日志:"
echo "  systemctl status haproxy"
echo "  journalctl -u haproxy -f"
echo
echo "改配置后:"
echo "  vim $TARGET_CFG"
echo "  haproxy -c -f $TARGET_CFG    # 语法检查"
echo "  systemctl reload haproxy     # 无 downtime 热加载"
