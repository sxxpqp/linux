#!/bin/bash
# 系统: Linux (systemd, CentOS 7+ / Ubuntu 20.04+)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/redis/fix-prod-fork.sh
# 用法:
#   单机: sudo bash fix-prod-fork.sh --host 127.0.0.1
#   集群: sudo bash fix-prod-fork.sh --host <seed-ip> --cluster
#   预演: sudo bash fix-prod-fork.sh --host <seed-ip> --cluster --dry-run
#
# 一键修复 Redis 生产 fork 慢 + 防误切换 — 三层加固:
#   ① OS:      关 THP / vm.overcommit_memory=1 / somaxconn 1024 / swappiness 1
#   ② Redis:   降低 RDB 频率 / appendfsync everysec / repl-diskless-sync yes
#   ③ Cluster: cluster-node-timeout 90s / min-replicas-to-write 1 / 防脑裂
#
# 特性: 幂等(跑两遍结果一样) + 进度可观测 + --dry-run + 错误给排查命令
#
# 配套文档: redis/capacity-planning.md "真实案例:24G 实例 fork 60s"

set -uo pipefail

# ===== 默认参数 =====
REDIS_HOST="127.0.0.1"
REDIS_PORT="6379"
REDIS_PASS=""
NODE_TIMEOUT="90000"
RDB_POLICY="low"      # off | low
SKIP_OS=false
SKIP_REDIS=false
SKIP_CLUSTER=false
DRY_RUN=false
IS_CLUSTER=false

# ===== 颜色输出 =====
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✓${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}  ✗${NC} $1" >&2; }
step() { echo; echo -e "${BLUE}═══ $1 ═══${NC}"; }

# ===== 参数解析 =====
while [ $# -gt 0 ]; do
  case "$1" in
    --host)         REDIS_HOST="$2"; shift 2 ;;
    --port)         REDIS_PORT="$2"; shift 2 ;;
    --password)     REDIS_PASS="$2"; shift 2 ;;
    --cluster)      IS_CLUSTER=true; shift ;;
    --node-timeout) NODE_TIMEOUT="$2"; shift 2 ;;
    --rdb-policy)   RDB_POLICY="$2"; shift 2 ;;
    --skip-os)      SKIP_OS=true; shift ;;
    --skip-redis)   SKIP_REDIS=true; shift ;;
    --skip-cluster) SKIP_CLUSTER=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) err "未知参数: $1"; exit 1 ;;
  esac
done

# ===== 参数校验 =====
case "$RDB_POLICY" in
  off|low) ;;
  *) err "--rdb-policy 必须是 off 或 low,你给的: $RDB_POLICY"; exit 1 ;;
esac
if ! [[ "$NODE_TIMEOUT" =~ ^[0-9]+$ ]] || [ "$NODE_TIMEOUT" -lt 10000 ]; then
  err "--node-timeout 必须是 >= 10000 的数字(毫秒),你给的: $NODE_TIMEOUT"
  exit 1
fi
if ! command -v redis-cli &>/dev/null; then
  err "找不到 redis-cli, 请先安装: yum install -y redis 或 apt install -y redis-tools"
  exit 1
fi

# ===== 包装 =====
# rcli: redis-cli 包装,自动加密码,dry-run 模式下写操作只打印
rcli() {
  local host="$1" port="$2"; shift 2
  if $DRY_RUN; then
    case "${1:-}${2:+ $2}" in
      "CONFIG SET"*|"CONFIG REWRITE"*)
        echo "  [dry-run] redis-cli -h $host -p $port $*" >&2
        return 0 ;;
    esac
  fi
  if [ -n "$REDIS_PASS" ]; then
    redis-cli -h "$host" -p "$port" -a "$REDIS_PASS" --no-auth-warning "$@" 2>/dev/null
  else
    redis-cli -h "$host" -p "$port" "$@" 2>/dev/null
  fi
}

# write_file: 幂等写文件,dry-run 模式只打印
write_file() {
  local path="$1" content="$2"
  if $DRY_RUN; then
    echo "  [dry-run] 写文件 $path (${#content} bytes)"
  else
    printf '%s' "$content" > "$path"
    ok "wrote $path"
  fi
}

# run: 普通命令包装(systemctl / sysctl 等)
run() {
  if $DRY_RUN; then
    echo "  [dry-run] $*"
    return 0
  fi
  "$@"
}

# ===== 头 =====
cat <<EOF

╔════════════════════════════════════════════════════════════╗
║   Redis 生产 fork 慢 + 误切换 三层修复脚本                 ║
║   OS / Redis / Cluster 一键加固, 幂等, 支持 --dry-run      ║
╚════════════════════════════════════════════════════════════╝

  REDIS_HOST:    $REDIS_HOST
  REDIS_PORT:    $REDIS_PORT
  CLUSTER 模式:  $IS_CLUSTER
  NODE_TIMEOUT:  $NODE_TIMEOUT ms
  RDB_POLICY:    $RDB_POLICY  (off=完全关 RDB, low=21600s/100w 变更才存)
  DRY_RUN:       $DRY_RUN
  SKIP_OS:       $SKIP_OS
  SKIP_REDIS:    $SKIP_REDIS
  SKIP_CLUSTER:  $SKIP_CLUSTER

EOF

# ===== ① OS 层 =====
if [ "$SKIP_OS" = false ]; then
  step "1/3 OS 层加固(本机)"

  if [ "$(id -u)" != "0" ] && [ "$DRY_RUN" = false ]; then
    err "OS 层需要 root, 跳过本步"
    warn "用 sudo 重跑, 或加 --skip-os 跳过(此时只改 Redis/Cluster)"
  else
    # ─ THP 临时 ─
    info "关闭 THP(临时即时生效)"
    if [ -w /sys/kernel/mm/transparent_hugepage/enabled ] || $DRY_RUN; then
      run sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
      run sh -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"
      ok "THP 当前: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo dry-run)"
    else
      err "/sys/kernel/mm/transparent_hugepage/enabled 不可写,跳过"
    fi

    # ─ THP systemd unit ─
    info "写 systemd unit 永久关 THP"
    if [ ! -f /etc/systemd/system/disable-thp.service ] || $DRY_RUN; then
      write_file /etc/systemd/system/disable-thp.service '[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=redis.service redis-server.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"
RemainAfterExit=yes

[Install]
WantedBy=basic.target
'
      run systemctl --no-pager daemon-reload
      run systemctl --no-pager enable --now disable-thp.service
      ok "disable-thp.service 已 enable + now"
    else
      ok "disable-thp.service 已存在,跳过(幂等)"
    fi

    # ─ sysctl ─
    info "写 sysctl 配置"
    if [ ! -f /etc/sysctl.d/99-redis.conf ] || $DRY_RUN; then
      write_file /etc/sysctl.d/99-redis.conf '# Redis 生产推荐 - by fix-prod-fork.sh
vm.overcommit_memory = 1
vm.swappiness = 1
net.core.somaxconn = 1024
'
      run sysctl --system >/dev/null 2>&1 || run sysctl -p /etc/sysctl.d/99-redis.conf >/dev/null 2>&1 || true
      ok "已应用: overcommit_memory=1 / swappiness=1 / somaxconn=1024"
    else
      ok "/etc/sysctl.d/99-redis.conf 已存在,跳过(幂等)"
      warn "  如要强制更新, 先 rm /etc/sysctl.d/99-redis.conf 再跑"
    fi
  fi
fi

# ===== 取节点列表 =====
NODES="$REDIS_HOST:$REDIS_PORT"
if $IS_CLUSTER; then
  step "拉取集群节点列表"
  CLUSTER_NODES=$(rcli "$REDIS_HOST" "$REDIS_PORT" CLUSTER NODES 2>/dev/null | awk '{print $2}' | cut -d@ -f1 | grep -E '^[0-9.]+:[0-9]+$' || true)
  if [ -n "$CLUSTER_NODES" ]; then
    NODES="$CLUSTER_NODES"
    info "找到 $(echo "$NODES" | wc -l | tr -d ' ') 个节点:"
    for n in $NODES; do echo "    - $n"; done
  else
    warn "无法获取集群节点(连接失败或非集群模式)→ 降级处理 $REDIS_HOST:$REDIS_PORT"
    warn "  排查: redis-cli -h $REDIS_HOST -p $REDIS_PORT CLUSTER INFO"
  fi
fi

# ===== ② Redis 单实例 =====
if [ "$SKIP_REDIS" = false ]; then
  step "2/3 Redis 配置加固(降低 fork 频率)"

  for node in $NODES; do
    HOST=${node%:*}; PORT=${node#*:}
    info "→ $HOST:$PORT"

    case "$RDB_POLICY" in
      off)
        rcli "$HOST" "$PORT" CONFIG SET save "" >/dev/null && ok "    RDB 已关闭 (save='')" ;;
      low)
        rcli "$HOST" "$PORT" CONFIG SET save "21600 1000000" >/dev/null && ok "    RDB 降频 (6h/100w 变更)" ;;
    esac

    rcli "$HOST" "$PORT" CONFIG SET appendfsync everysec >/dev/null
    rcli "$HOST" "$PORT" CONFIG SET auto-aof-rewrite-percentage 200 >/dev/null
    rcli "$HOST" "$PORT" CONFIG SET auto-aof-rewrite-min-size 4gb >/dev/null
    rcli "$HOST" "$PORT" CONFIG SET repl-diskless-sync yes >/dev/null
    rcli "$HOST" "$PORT" CONFIG SET repl-diskless-sync-delay 5 >/dev/null
    rcli "$HOST" "$PORT" CONFIG REWRITE >/dev/null 2>&1 || true   # 没 config file 时报错,忽略
    ok "    AOF everysec + auto-rewrite 阈值上调 + diskless-sync"
  done
fi

# ===== ③ 集群参数 =====
if $IS_CLUSTER && [ "$SKIP_CLUSTER" = false ]; then
  step "3/3 集群参数加固(防误切换 + 防脑裂)"

  for node in $NODES; do
    HOST=${node%:*}; PORT=${node#*:}
    info "→ $HOST:$PORT"
    rcli "$HOST" "$PORT" CONFIG SET cluster-node-timeout "$NODE_TIMEOUT" >/dev/null
    rcli "$HOST" "$PORT" CONFIG SET min-replicas-to-write 1 >/dev/null
    rcli "$HOST" "$PORT" CONFIG SET min-replicas-max-lag 10 >/dev/null
    rcli "$HOST" "$PORT" CONFIG SET cluster-require-full-coverage no >/dev/null
    rcli "$HOST" "$PORT" CONFIG REWRITE >/dev/null 2>&1 || true
    ok "    node-timeout=${NODE_TIMEOUT}ms / min-replicas-to-write=1 / max-lag=10s"
  done
fi

# ===== 验证 =====
step "验证"

if [ "$SKIP_OS" = false ]; then
  echo "OS 层:"
  printf "  %-22s %s\n" "THP enabled:"        "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
  printf "  %-22s %s\n" "overcommit_memory:"  "$(sysctl -n vm.overcommit_memory 2>/dev/null || echo n/a) (期望 1)"
  printf "  %-22s %s\n" "swappiness:"         "$(sysctl -n vm.swappiness 2>/dev/null || echo n/a) (期望 1)"
  printf "  %-22s %s\n" "somaxconn:"          "$(sysctl -n net.core.somaxconn 2>/dev/null || echo n/a) (期望 >= 1024)"
  printf "  %-22s %s\n" "Swap used:"          "$(free -m 2>/dev/null | awk '/^Swap:/{print $3" MB"}' || echo n/a)"
  echo
fi

echo "Redis $REDIS_HOST:$REDIS_PORT:"
CURRENT_SAVE=$(rcli "$REDIS_HOST" "$REDIS_PORT" CONFIG GET save 2>/dev/null | tail -1)
CURRENT_DISKLESS=$(rcli "$REDIS_HOST" "$REDIS_PORT" CONFIG GET repl-diskless-sync 2>/dev/null | tail -1)
CURRENT_FORK=$(rcli "$REDIS_HOST" "$REDIS_PORT" INFO stats 2>/dev/null | grep -i latest_fork_usec | tr -d '\r' | cut -d: -f2)
printf "  %-22s %s\n" "save:"                 "${CURRENT_SAVE:-?}"
printf "  %-22s %s\n" "repl-diskless-sync:"   "${CURRENT_DISKLESS:-?} (期望 yes)"
printf "  %-22s %s\n" "latest_fork_usec:"     "${CURRENT_FORK:-?} us (期望 < 500000)"

if $IS_CLUSTER; then
  echo
  echo "Cluster:"
  printf "  %-30s %s\n" "node-timeout:"               "$(rcli "$REDIS_HOST" "$REDIS_PORT" CONFIG GET cluster-node-timeout 2>/dev/null | tail -1) (期望 $NODE_TIMEOUT)"
  printf "  %-30s %s\n" "min-replicas-to-write:"      "$(rcli "$REDIS_HOST" "$REDIS_PORT" CONFIG GET min-replicas-to-write 2>/dev/null | tail -1) (期望 1)"
  printf "  %-30s %s\n" "min-replicas-max-lag:"       "$(rcli "$REDIS_HOST" "$REDIS_PORT" CONFIG GET min-replicas-max-lag 2>/dev/null | tail -1) (期望 10)"
  printf "  %-30s %s\n" "cluster-require-full-cover:" "$(rcli "$REDIS_HOST" "$REDIS_PORT" CONFIG GET cluster-require-full-coverage 2>/dev/null | tail -1) (期望 no)"
  FAILED=$(rcli "$REDIS_HOST" "$REDIS_PORT" CLUSTER NODES 2>/dev/null | awk '$3 ~ /fail/' | wc -l | tr -d ' ')
  printf "  %-30s %s\n" "failed nodes:"               "$FAILED (期望 0)"
fi

echo
ok "完成"
echo
echo "下一步:"
echo "  ① 主动触发一次 fork 验证(关键!):"
echo "     redis-cli -h $REDIS_HOST -p $REDIS_PORT BGSAVE && sleep 5 && \\"
echo "     redis-cli -h $REDIS_HOST -p $REDIS_PORT INFO stats | grep latest_fork_usec"
echo "     (期望从 60s 暴降到 < 500ms)"
echo "  ② 24-48h 后再跑一次本脚本, 看 latest_fork_usec 仍然小"
echo "  ③ 长期: 机械盘换 SSD, 24G 实例拆 8G ×3 分片"
echo
echo "再次出问题时排查:"
echo "  redis-cli -h $REDIS_HOST -p $REDIS_PORT LATENCY HISTORY fork"
echo "  redis-cli -h $REDIS_HOST -p $REDIS_PORT --bigkeys"
echo "  redis-cli -h $REDIS_HOST -p $REDIS_PORT CLUSTER NODES | grep fail"
echo "  journalctl -u redis -n 100 --no-pager"
