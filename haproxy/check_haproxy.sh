#!/usr/bin/env bash
# ============================================================
# HAProxy 健康检查 — 给 Keepalived track_script 用
# ============================================================
# 退出码:
#   0 = 健康          (Keepalived 保持当前优先级)
#   1 = 不健康        (Keepalived 按 weight 扣分,触发 VIP 漂移)
#
# 在 /etc/keepalived/keepalived.conf 里引用:
#
#   vrrp_script chk_haproxy {
#       script   "/etc/keepalived/check_haproxy.sh"
#       interval 2          # 每 2s 检查一次
#       weight   -20        # 失败减 20 优先级,让对端接管
#       rise     2          # 连续 2 次成功才认健康
#       fall     3          # 连续 3 次失败才认挂掉(防抖)
#       timeout  3
#       user     root
#   }
#
#   vrrp_instance VI_1 {
#       ...
#       track_script {
#           chk_haproxy
#       }
#   }
#
# 自测:
#   ./check_haproxy.sh && echo OK || echo FAIL
#   # 模拟挂掉:
#   systemctl stop haproxy && ./check_haproxy.sh; echo $?
# ============================================================

set -u

STATS_PORT="${STATS_PORT:-8404}"
TIMEOUT="${TIMEOUT:-2}"

# 失败输出到 stderr,keepalived 会写入 syslog,方便事后排障
fail() {
    echo "[check_haproxy] FAIL: $*" >&2
    exit 1
}

# ---- 1. 进程存在 ----
# 注意:用 -x 精确匹配进程名,避免 grep 自己
pgrep -x haproxy >/dev/null || fail "haproxy process not running"

# ---- 2. 关键端口监听(80 / 443 至少一个在听) ----
# 进程在但 listener 没起来(配置错 / bind 失败)也算挂
LISTENING=0
for port in 80 443; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${port}\$"; then
        LISTENING=$((LISTENING + 1))
    fi
done
[ "$LISTENING" -gt 0 ] || fail "no HAProxy frontend listening on 80/443"

# ---- 3. stats 页能访问(进程活但内部死锁/线程卡死的兜底) ----
# 仅 pgrep + ss 检查不够:HAProxy 进程在,worker 线程全死锁的 case 是真实存在的
curl -fs --max-time "$TIMEOUT" "http://127.0.0.1:${STATS_PORT}/" -o /dev/null 2>/dev/null \
    || fail "stats endpoint :${STATS_PORT} not responding"

# ---- 4.(可选,默认关闭)所有后端 server 都 DOWN 时也判定本机不健康 ----
# 开启后会更激进,但启动初期或后端故障时易抖动,谨慎使用
# 用 STRICT_BACKEND=1 启用:
#   environment="STRICT_BACKEND=1" 在 systemd 里设,或脚本里 export
if [ "${STRICT_BACKEND:-0}" = "1" ]; then
    CSV=$(curl -fs --max-time "$TIMEOUT" "http://127.0.0.1:${STATS_PORT}/stats;csv" 2>/dev/null \
        || curl -fs --max-time "$TIMEOUT" "http://127.0.0.1:${STATS_PORT}/?stats;csv" 2>/dev/null \
        || true)
    if [ -n "$CSV" ]; then
        # 第 2 列 = svname,第 18 列 = status;过滤掉 FRONTEND / BACKEND 汇总行
        UP=$(echo "$CSV" | awk -F, '$2 != "FRONTEND" && $2 != "BACKEND" && $18 == "UP"' | wc -l)
        [ "$UP" -gt 0 ] || fail "all backend servers are DOWN"
    fi
fi

exit 0
