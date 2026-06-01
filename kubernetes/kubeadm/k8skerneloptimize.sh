#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeadm/k8skerneloptimize.sh
# ============================================================
# 许愿狐 (Wishfoxs) K8s 节点内核优化脚本
# 支持: CentOS 7/8, Rocky Linux 8/9, Ubuntu 20.04/22.04/24.04
# 执行方式: bash k8s-kernel-optimize.sh [--dry-run] [--check-only]
# ============================================================

set -uo pipefail

# ──────────────────────────────────────────────
# 颜色
# ──────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'
DIM='\033[2m'; RESET='\033[0m'

# ──────────────────────────────────────────────
# 模式控制
# ──────────────────────────────────────────────
DRY_RUN=false
CHECK_ONLY=false
for arg in "$@"; do
    [[ "$arg" == "--dry-run"    ]] && DRY_RUN=true
    [[ "$arg" == "--check-only" ]] && CHECK_ONLY=true
done

APPLY=true
$DRY_RUN    && APPLY=false
$CHECK_ONLY && APPLY=false

# ──────────────────────────────────────────────
# 工具函数
# ──────────────────────────────────────────────
header() {
    echo ""
    echo -e "${BLUE}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
    printf  "${BLUE}${BOLD}║  %-60s║${RESET}\n" "$1"
    echo -e "${BLUE}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
}
section() { echo -e "\n${CYAN}${BOLD}▶ $1${RESET}\n${CYAN}$(printf '─%.0s' {1..50})${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $1"; }
err()     { echo -e "  ${RED}✗${RESET} $1"; }
info()    { echo -e "  ${DIM}│${RESET} $1"; }
changed() { echo -e "  ${CYAN}→${RESET} $1"; }

run_cmd() {
    local desc="$1"; shift
    if $DRY_RUN; then
        echo -e "  ${DIM}[DRY-RUN]${RESET} $*"
    elif $CHECK_ONLY; then
        : # 不执行
    else
        eval "$@" && changed "${desc}" || warn "${desc} 执行失败，请手动执行: $*"
    fi
}

# ──────────────────────────────────────────────
# 检测操作系统 & 内核
# ──────────────────────────────────────────────
detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="${ID}"
        OS_VER="${VERSION_ID%%.*}"
        OS_NAME="${PRETTY_NAME}"
    else
        OS_ID="unknown"
        OS_VER="0"
        OS_NAME="Unknown OS"
    fi

    KERNEL_FULL=$(uname -r)
    KERNEL_MAJOR=$(uname -r | cut -d. -f1)
    KERNEL_MINOR=$(uname -r | cut -d. -f2)
    ARCH=$(uname -m)
    CPU_CORES=$(nproc)
    TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_MEM_GB=$(( TOTAL_MEM_KB / 1024 / 1024 ))
    HOSTNAME=$(hostname)

    # 判断是否是 K8s 节点
    IS_K8S_NODE=false
    command -v kubelet &>/dev/null && IS_K8S_NODE=true
    [[ -f /var/lib/kubelet/config.yaml ]] && IS_K8S_NODE=true

    # 判断 PKG 管理器
    if command -v yum &>/dev/null; then
        PKG_MGR="yum"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v apt-get &>/dev/null; then
        PKG_MGR="apt"
    else
        PKG_MGR="unknown"
    fi
}

# ──────────────────────────────────────────────
# sysctl 参数检查 & 应用
# ──────────────────────────────────────────────
CHANGED_PARAMS=0
ALREADY_OK=0
SKIPPED=0

check_and_set() {
    local key="$1"
    local expected="$2"
    local desc="$3"
    local current
    current=$(sysctl -n "${key}" 2>/dev/null || echo "__NOT_FOUND__")

    if [[ "${current}" == "__NOT_FOUND__" ]]; then
        warn "${key} — 内核不支持此参数，跳过"
        (( SKIPPED++ )) || true
        return
    fi

    # 规范化空白（有些参数值含空格如 ip_local_port_range）
    current=$(echo "${current}" | xargs)
    expected_norm=$(echo "${expected}" | xargs)

    if [[ "${current}" == "${expected_norm}" ]]; then
        ok "${key} = ${current}  ✓ (${desc})"
        (( ALREADY_OK++ )) || true
    else
        warn "${key}: 当前=${current}  期望=${expected_norm}  (${desc})"
        if $APPLY; then
            sysctl -w "${key}=${expected}" &>/dev/null && \
                changed "已设置 ${key}=${expected}" || \
                err "设置失败: ${key}=${expected}"
            (( CHANGED_PARAMS++ )) || true
        elif $DRY_RUN; then
            echo -e "  ${DIM}[DRY-RUN] sysctl -w ${key}=${expected}${RESET}"
        fi
    fi
}

# ══════════════════════════════════════════════
# 主程序
# ══════════════════════════════════════════════
detect_os

header "K8s 节点内核优化 | ${HOSTNAME} | $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
info "操作系统   : ${OS_NAME}"
info "内核版本   : ${KERNEL_FULL}"
info "CPU架构    : ${ARCH} (${CPU_CORES}核)"
info "内存       : ${TOTAL_MEM_GB} GB"
info "K8s节点    : ${IS_K8S_NODE}"
info "包管理器   : ${PKG_MGR}"
info "运行模式   : $( $DRY_RUN && echo 'DRY-RUN(仅预览)' || $CHECK_ONLY && echo 'CHECK-ONLY(仅检查)' || echo '应用模式(会修改配置)' )"

# ──────────────────────────────────────────────
# 0. Root 检查
# ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]] && $APPLY; then
    err "应用模式需要 root 权限，请使用 sudo 执行"
    exit 1
fi

# ══════════════════════════════════════════════
# 一、内核版本检查与升级建议
# ══════════════════════════════════════════════
header "一、内核版本评估"

section "当前内核版本"
info "内核: ${KERNEL_FULL}"

KERNEL_OK=false
case "${OS_ID}" in
    centos|rhel)
        if [[ "${OS_VER}" -eq 7 ]]; then
            if [[ "${KERNEL_MAJOR}" -ge 5 ]]; then
                ok "CentOS 7 已升级到高版本内核 ${KERNEL_FULL}（推荐 5.15+）"
                KERNEL_OK=true
            else
                err "CentOS 7 默认内核 ${KERNEL_FULL} 过旧，K8s 需要 ≥ 4.19，强烈建议升级到 5.15（kernel-ml）"
                echo ""
                echo -e "  ${YELLOW}${BOLD}升级步骤（CentOS 7）：${RESET}"
                cat << 'EOF'
  # 1. 添加 ELRepo 仓库
  rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
  yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm

  # 2. 安装 kernel-ml（主线版本 6.x）或 kernel-lt（长期支持 5.15）
  yum --enablerepo=elrepo-kernel install -y kernel-ml
  # 或
  yum --enablerepo=elrepo-kernel install -y kernel-lt

  # 3. 设置默认启动内核
  grub2-set-default 0
  grub2-mkconfig -o /boot/grub2/grub.cfg

  # 4. 重启
  reboot
EOF
            fi
        elif [[ "${OS_VER}" -ge 8 ]]; then
            ok "CentOS/RHEL ${OS_VER} 内核 ${KERNEL_FULL} — 满足要求"
            KERNEL_OK=true
        fi
        ;;
    rocky|almalinux)
        if [[ "${KERNEL_MAJOR}" -ge 5 ]]; then
            ok "Rocky/AlmaLinux 内核 ${KERNEL_FULL} — 满足要求"
            KERNEL_OK=true
        else
            warn "内核 ${KERNEL_FULL} 偏旧，建议升级"
        fi
        ;;
    ubuntu|debian)
        if [[ "${KERNEL_MAJOR}" -ge 5 && "${KERNEL_MINOR}" -ge 15 ]] || [[ "${KERNEL_MAJOR}" -ge 6 ]]; then
            ok "Ubuntu/Debian 内核 ${KERNEL_FULL} — 满足要求"
            KERNEL_OK=true
        else
            warn "内核 ${KERNEL_FULL} 建议升级到 5.15+ 或 6.x"
            echo ""
            echo -e "  ${YELLOW}${BOLD}升级步骤（Ubuntu）：${RESET}"
            cat << 'EOF'
  apt update && apt install -y linux-image-generic-hwe-22.04
  # 或指定版本
  apt install -y linux-image-6.5.0-generic
  reboot
EOF
        fi
        ;;
    *)
        warn "未识别的操作系统 ${OS_ID}，请手动确认内核版本"
        ;;
esac

# ══════════════════════════════════════════════
# 二、必要内核模块
# ══════════════════════════════════════════════
header "二、内核模块检查"

section "K8s 必要模块"
REQUIRED_MODULES=(
    "overlay"          # 容器 OverlayFS
    "br_netfilter"     # 桥接网络过滤（K8s网络必需）
    "ip_vs"            # kube-proxy IPVS 模式
    "ip_vs_rr"         # IPVS 轮询算法
    "ip_vs_wrr"        # IPVS 加权轮询
    "ip_vs_sh"         # IPVS 源哈希
    "nf_conntrack"     # 连接跟踪
)

# Cilium 额外需要
CILIUM_MODULES=(
    "xt_socket"
    "xt_mark"
    "xt_multiport"
    "ipt_REDIRECT"
    "ipt_TPROXY"
)

for mod in "${REQUIRED_MODULES[@]}"; do
    if lsmod | grep -q "^${mod}"; then
        ok "模块 ${mod} 已加载"
    else
        warn "模块 ${mod} 未加载"
        if $APPLY; then
            modprobe "${mod}" 2>/dev/null && changed "已加载模块 ${mod}" || err "加载模块 ${mod} 失败"
        elif $DRY_RUN; then
            echo -e "  ${DIM}[DRY-RUN] modprobe ${mod}${RESET}"
        fi
    fi
done

section "Cilium CNI 模块（你们用的CNI）"
for mod in "${CILIUM_MODULES[@]}"; do
    if lsmod | grep -q "^${mod}"; then
        ok "Cilium模块 ${mod} 已加载"
    else
        warn "Cilium模块 ${mod} 未加载"
        $APPLY && modprobe "${mod}" 2>/dev/null && changed "已加载 ${mod}" || true
    fi
done

section "持久化模块加载（开机自动）"
MODULES_CONF="/etc/modules-load.d/k8s.conf"
if [[ -f "${MODULES_CONF}" ]]; then
    ok "模块配置文件已存在: ${MODULES_CONF}"
    cat "${MODULES_CONF}" | while read -r line; do info "  ${line}"; done
else
    warn "模块配置文件不存在: ${MODULES_CONF}"
    if $APPLY; then
        cat > "${MODULES_CONF}" << 'EOF'
# K8s 必要内核模块 - 由 k8s-kernel-optimize.sh 生成
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
# Cilium
xt_socket
xt_mark
xt_multiport
ipt_REDIRECT
EOF
        changed "已创建 ${MODULES_CONF}"
    elif $DRY_RUN; then
        echo -e "  ${DIM}[DRY-RUN] 创建 ${MODULES_CONF}${RESET}"
    fi
fi

# ══════════════════════════════════════════════
# 三、sysctl 内核参数优化
# ══════════════════════════════════════════════
header "三、sysctl 内核参数优化"

SYSCTL_CONF="/etc/sysctl.d/99-k8s-wishfox.conf"

section "3.1 网络基础（K8s 必需）"
check_and_set "net.bridge.bridge-nf-call-iptables"  "1"   "桥接流量走iptables（K8s网络必需）"
check_and_set "net.bridge.bridge-nf-call-ip6tables" "1"   "IPv6桥接流量过滤"
check_and_set "net.ipv4.ip_forward"                 "1"   "开启IP转发（Pod间通信必需）"
check_and_set "net.ipv6.conf.all.forwarding"        "1"   "IPv6转发"

section "3.2 连接跟踪表（nf_conntrack）"
# 根据内存动态计算连接跟踪表大小
CONNTRACK_MAX=$(( TOTAL_MEM_GB * 65536 ))
[[ $CONNTRACK_MAX -lt 524288  ]] && CONNTRACK_MAX=524288
[[ $CONNTRACK_MAX -gt 4194304 ]] && CONNTRACK_MAX=4194304
CONNTRACK_BUCKETS=$(( CONNTRACK_MAX / 4 ))

info "根据内存 ${TOTAL_MEM_GB}GB 计算: nf_conntrack_max=${CONNTRACK_MAX}"
check_and_set "net.netfilter.nf_conntrack_max"             "${CONNTRACK_MAX}"  "连接跟踪表大小（K8s高并发必需）"
check_and_set "net.netfilter.nf_conntrack_tcp_timeout_established" "86400"    "已建立连接超时(秒)"
check_and_set "net.netfilter.nf_conntrack_tcp_timeout_close_wait"  "3600"     "CLOSE_WAIT超时"
check_and_set "net.netfilter.nf_conntrack_tcp_timeout_fin_wait"    "30"       "FIN_WAIT超时"
check_and_set "net.netfilter.nf_conntrack_tcp_timeout_time_wait"   "30"       "TIME_WAIT超时"

# 哈希桶大小（写入模块参数）
if $APPLY; then
    if [[ -f /sys/module/nf_conntrack/parameters/hashsize ]]; then
        echo "${CONNTRACK_BUCKETS}" > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null && \
            changed "nf_conntrack hashsize=${CONNTRACK_BUCKETS}" || true
        # 持久化
        echo "options nf_conntrack hashsize=${CONNTRACK_BUCKETS}" > /etc/modprobe.d/nf_conntrack.conf
    fi
fi

section "3.3 TCP 性能优化"
check_and_set "net.ipv4.tcp_tw_reuse"          "1"         "TIME_WAIT 连接复用"
check_and_set "net.ipv4.tcp_fin_timeout"       "15"        "FIN_WAIT2 超时(秒)"
check_and_set "net.ipv4.tcp_keepalive_time"    "600"       "TCP KeepAlive 探测间隔(秒)"
check_and_set "net.ipv4.tcp_keepalive_probes"  "3"         "KeepAlive 探测失败次数"
check_and_set "net.ipv4.tcp_keepalive_intvl"   "15"        "KeepAlive 探测间隔(秒)"
check_and_set "net.ipv4.tcp_max_tw_buckets"    "36000"     "TIME_WAIT 最大连接数"
check_and_set "net.ipv4.tcp_max_syn_backlog"   "8192"      "SYN 半连接队列长度"
check_and_set "net.ipv4.tcp_syncookies"        "1"         "防 SYN Flood 攻击"
check_and_set "net.ipv4.tcp_synack_retries"    "2"         "SYN-ACK 重试次数"
check_and_set "net.ipv4.tcp_syn_retries"       "3"         "SYN 重试次数"
check_and_set "net.ipv4.tcp_slow_start_after_idle" "0"     "禁止空闲后慢启动（长连接优化）"
check_and_set "net.ipv4.ip_local_port_range"   "10240 65535" "本地端口范围（K8s大量端口）"

section "3.4 TCP 缓冲区"
# 根据内存动态设置
RMEM_MAX=$(( TOTAL_MEM_GB * 4 * 1024 * 1024 ))
[[ $RMEM_MAX -lt 16777216  ]] && RMEM_MAX=16777216    # 最小 16MB
[[ $RMEM_MAX -gt 536870912 ]] && RMEM_MAX=536870912   # 最大 512MB
WMEM_MAX=$RMEM_MAX

info "根据内存 ${TOTAL_MEM_GB}GB 计算缓冲区: ${RMEM_MAX} bytes"
check_and_set "net.core.rmem_max"              "${RMEM_MAX}"          "Socket 最大接收缓冲"
check_and_set "net.core.wmem_max"              "${WMEM_MAX}"          "Socket 最大发送缓冲"
check_and_set "net.core.rmem_default"          "262144"               "Socket 默认接收缓冲"
check_and_set "net.core.wmem_default"          "262144"               "Socket 默认发送缓冲"
check_and_set "net.ipv4.tcp_rmem"              "4096 87380 ${RMEM_MAX}" "TCP接收缓冲 min/default/max"
check_and_set "net.ipv4.tcp_wmem"              "4096 65536 ${WMEM_MAX}" "TCP发送缓冲 min/default/max"
check_and_set "net.ipv4.tcp_mem"               "94500000 915000000 927000000" "TCP内存压力阈值"
check_and_set "net.core.netdev_max_backlog"    "16384"                "网卡收包队列长度"
check_and_set "net.core.somaxconn"             "32768"                "监听队列最大长度"
check_and_set "net.core.optmem_max"            "81920"                "Socket 附加内存"

section "3.5 内存管理"
check_and_set "vm.swappiness"                  "0"    "禁用 Swap（K8s 强烈要求）"
check_and_set "vm.overcommit_memory"           "1"    "内存过度分配（避免 OOM Killer 误杀）"
check_and_set "vm.overcommit_ratio"            "50"   "过度分配比例"
check_and_set "vm.panic_on_oom"                "0"    "OOM 时不 panic，触发 OOM Killer"
check_and_set "vm.dirty_ratio"                 "15"   "脏页比例上限（超过开始强制写盘）"
check_and_set "vm.dirty_background_ratio"      "5"    "脏页后台刷写触发比例"
check_and_set "vm.dirty_expire_centisecs"      "3000" "脏页过期时间(厘秒)"
check_and_set "vm.dirty_writeback_centisecs"   "500"  "脏页回写间隔(厘秒)"
check_and_set "vm.min_free_kbytes"             "$(( TOTAL_MEM_GB * 1024 * 16 ))" "最小保留空闲内存(KB)"
check_and_set "vm.zone_reclaim_mode"           "0"    "禁用 NUMA zone 回收（避免性能抖动）"

section "3.6 文件系统"
FS_MAX=$(( TOTAL_MEM_GB * 100000 ))
[[ $FS_MAX -lt 1000000  ]] && FS_MAX=1000000
[[ $FS_MAX -gt 10000000 ]] && FS_MAX=10000000

check_and_set "fs.file-max"                    "${FS_MAX}"  "系统最大文件描述符"
check_and_set "fs.inotify.max_user_instances"  "8192"       "inotify 最大实例数（K8s watch 多）"
check_and_set "fs.inotify.max_user_watches"    "1048576"    "inotify 最大 watch 数"
check_and_set "fs.inotify.max_queued_events"   "32768"      "inotify 事件队列"
check_and_set "fs.pipe-max-size"               "4194304"    "管道最大容量"
check_and_set "kernel.pid_max"                 "4194304"    "最大进程 ID（K8s 大量容器）"
check_and_set "kernel.threads-max"             "$(( TOTAL_MEM_GB * 4096 ))"   "最大线程数"

section "3.7 IPVS 优化（kube-proxy IPVS 模式）"
check_and_set "net.ipv4.vs.conn_reuse_mode"    "0"    "IPVS 连接复用模式"
check_and_set "net.ipv4.vs.expire_nodest_conn" "1"    "IPVS 清理无目标连接"
check_and_set "net.ipv4.vs.expire_quiescent_template" "1" "IPVS 模板过期"

section "3.8 内核安全"
check_and_set "kernel.dmesg_restrict"          "1"    "限制非特权用户读取 dmesg"
check_and_set "kernel.kptr_restrict"           "1"    "隐藏内核符号地址"
check_and_set "net.ipv4.conf.all.rp_filter"    "1"    "反向路径过滤（防 IP 欺骗）"
check_and_set "net.ipv4.conf.default.rp_filter" "1"   "默认接口反向路径过滤"
check_and_set "net.ipv4.icmp_echo_ignore_broadcasts" "1" "忽略广播 ping"

# 持久化 sysctl 配置
section "3.9 持久化配置"
if $APPLY; then
    cat > "${SYSCTL_CONF}" << EOF
# ============================================================
# 许愿狐 K8s 节点内核参数优化
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# 内存: ${TOTAL_MEM_GB}GB  CPU: ${CPU_CORES}核
# ============================================================

# ── K8s 网络必需 ──────────────────────────────
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1

# ── 连接跟踪 ─────────────────────────────────
net.netfilter.nf_conntrack_max                          = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established      = 86400
net.netfilter.nf_conntrack_tcp_timeout_close_wait       = 3600
net.netfilter.nf_conntrack_tcp_timeout_fin_wait         = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait        = 30

# ── TCP 性能 ──────────────────────────────────
net.ipv4.tcp_tw_reuse           = 1
net.ipv4.tcp_fin_timeout        = 15
net.ipv4.tcp_keepalive_time     = 600
net.ipv4.tcp_keepalive_probes   = 3
net.ipv4.tcp_keepalive_intvl    = 15
net.ipv4.tcp_max_tw_buckets     = 36000
net.ipv4.tcp_max_syn_backlog    = 8192
net.ipv4.tcp_syncookies         = 1
net.ipv4.tcp_synack_retries     = 2
net.ipv4.tcp_syn_retries        = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range    = 10240 65535

# ── TCP 缓冲区 ────────────────────────────────
net.core.rmem_max               = ${RMEM_MAX}
net.core.wmem_max               = ${WMEM_MAX}
net.core.rmem_default           = 262144
net.core.wmem_default           = 262144
net.ipv4.tcp_rmem               = 4096 87380 ${RMEM_MAX}
net.ipv4.tcp_wmem               = 4096 65536 ${WMEM_MAX}
net.ipv4.tcp_mem                = 94500000 915000000 927000000
net.core.netdev_max_backlog     = 16384
net.core.somaxconn              = 32768
net.core.optmem_max             = 81920

# ── 内存管理 ──────────────────────────────────
vm.swappiness                   = 0
vm.overcommit_memory            = 1
vm.overcommit_ratio             = 50
vm.panic_on_oom                 = 0
vm.dirty_ratio                  = 15
vm.dirty_background_ratio       = 5
vm.dirty_expire_centisecs       = 3000
vm.dirty_writeback_centisecs    = 500
vm.min_free_kbytes              = $(( TOTAL_MEM_GB * 1024 * 16 ))
vm.zone_reclaim_mode            = 0

# ── 文件系统 ──────────────────────────────────
fs.file-max                     = ${FS_MAX}
fs.inotify.max_user_instances   = 8192
fs.inotify.max_user_watches     = 1048576
fs.inotify.max_queued_events    = 32768
fs.pipe-max-size                = 4194304
kernel.pid_max                  = 4194304
kernel.threads-max              = $(( TOTAL_MEM_GB * 4096 ))

# ── IPVS ─────────────────────────────────────
net.ipv4.vs.conn_reuse_mode             = 0
net.ipv4.vs.expire_nodest_conn          = 1
net.ipv4.vs.expire_quiescent_template   = 1

# ── 安全 ─────────────────────────────────────
kernel.dmesg_restrict                   = 1
kernel.kptr_restrict                    = 1
net.ipv4.conf.all.rp_filter             = 1
net.ipv4.conf.default.rp_filter         = 1
net.ipv4.icmp_echo_ignore_broadcasts    = 1
EOF
    sysctl --system &>/dev/null && changed "sysctl 配置已持久化到 ${SYSCTL_CONF} 并生效" || \
        warn "持久化成功，但 sysctl --system 有警告（部分参数可能需重启生效）"
elif $DRY_RUN; then
    echo -e "  ${DIM}[DRY-RUN] 将写入 ${SYSCTL_CONF}${RESET}"
fi

# ══════════════════════════════════════════════
# 四、系统限制（ulimit / limits.conf）
# ══════════════════════════════════════════════
header "四、系统资源限制 (ulimit)"

section "4.1 当前用户限制"
NOFILE_SOFT=$(ulimit -Sn 2>/dev/null || echo "unknown")
NOFILE_HARD=$(ulimit -Hn 2>/dev/null || echo "unknown")
NPROC_SOFT=$(ulimit -Su 2>/dev/null  || echo "unknown")
NPROC_HARD=$(ulimit -Hu 2>/dev/null  || echo "unknown")

info "文件描述符(soft) : ${NOFILE_SOFT}"
info "文件描述符(hard) : ${NOFILE_HARD}"
info "最大进程数(soft) : ${NPROC_SOFT}"
info "最大进程数(hard) : ${NPROC_HARD}"

[[ "${NOFILE_SOFT}" -lt 1048576 ]] 2>/dev/null && warn "文件描述符 soft 限制偏低(${NOFILE_SOFT})" || ok "文件描述符 soft 限制正常"
[[ "${NOFILE_HARD}" -lt 1048576 ]] 2>/dev/null && warn "文件描述符 hard 限制偏低(${NOFILE_HARD})" || ok "文件描述符 hard 限制正常"

section "4.2 设置系统限制"
LIMITS_CONF="/etc/security/limits.d/99-k8s-wishfox.conf"
if [[ -f "${LIMITS_CONF}" ]]; then
    ok "limits 配置文件已存在: ${LIMITS_CONF}"
else
    warn "limits 配置文件不存在，需要创建"
    if $APPLY; then
        cat > "${LIMITS_CONF}" << 'EOF'
# 许愿狐 K8s 节点资源限制优化
# 由 k8s-kernel-optimize.sh 生成
*       soft    nofile      1048576
*       hard    nofile      1048576
*       soft    nproc       unlimited
*       hard    nproc       unlimited
*       soft    memlock     unlimited
*       hard    memlock     unlimited
*       soft    stack       unlimited
*       hard    stack       unlimited
root    soft    nofile      1048576
root    hard    nofile      1048576
EOF
        changed "已创建 ${LIMITS_CONF}"
    elif $DRY_RUN; then
        echo -e "  ${DIM}[DRY-RUN] 创建 ${LIMITS_CONF}${RESET}"
    fi
fi

section "4.3 systemd 服务限制（containerd / kubelet）"
for svc in containerd kubelet docker; do
    SVC_DIR="/etc/systemd/system/${svc}.service.d"
    SVC_CONF="${SVC_DIR}/limits.conf"
    if systemctl is-active "${svc}" &>/dev/null; then
        if [[ -f "${SVC_CONF}" ]]; then
            ok "${svc} systemd 限制已配置"
        else
            warn "${svc} 未配置 systemd 资源限制"
            if $APPLY; then
                mkdir -p "${SVC_DIR}"
                cat > "${SVC_CONF}" << EOF
[Service]
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
EOF
                changed "已创建 ${SVC_CONF}"
            elif $DRY_RUN; then
                echo -e "  ${DIM}[DRY-RUN] 创建 ${SVC_CONF}${RESET}"
            fi
        fi
    fi
done

# ══════════════════════════════════════════════
# 五、Swap 处理
# ══════════════════════════════════════════════
header "五、Swap 配置"

section "5.1 Swap 状态"
SWAP_ON=$(swapon --show 2>/dev/null | grep -v '^NAME' | wc -l)
if [[ "${SWAP_ON}" -eq 0 ]]; then
    ok "Swap 已关闭 ✓（K8s 要求）"
else
    err "Swap 未关闭！检测到 ${SWAP_ON} 个 Swap 分区/文件（K8s 默认要求关闭 Swap）"
    swapon --show 2>/dev/null | while read -r line; do info "  ${line}"; done
    if $APPLY; then
        swapoff -a && changed "已临时关闭 Swap（重启后需确认 /etc/fstab）"
        sed -i '/swap/d' /etc/fstab 2>/dev/null && changed "已从 /etc/fstab 移除 Swap 挂载"
    elif $DRY_RUN; then
        echo -e "  ${DIM}[DRY-RUN] swapoff -a && sed -i '/swap/d' /etc/fstab${RESET}"
    fi
fi

# ══════════════════════════════════════════════
# 六、OS 差异化优化
# ══════════════════════════════════════════════
header "六、发行版差异化优化"

case "${OS_ID}" in

    # ──────────────────────────────────────────
    # CentOS 7 专项
    # ──────────────────────────────────────────
    centos)
        if [[ "${OS_VER}" -eq 7 ]]; then
            section "CentOS 7 专项优化"

            # SELinux
            SELINUX_STATUS=$(getenforce 2>/dev/null || echo "unknown")
            info "SELinux 状态: ${SELINUX_STATUS}"
            if [[ "${SELINUX_STATUS}" == "Enforcing" ]]; then
                warn "SELinux Enforcing — K8s 建议设为 Permissive 或 Disabled"
                if $APPLY; then
                    setenforce 0 && changed "SELinux 临时设为 Permissive"
                    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config && \
                        changed "SELinux 永久设为 Permissive（重启生效）"
                elif $DRY_RUN; then
                    echo -e "  ${DIM}[DRY-RUN] setenforce 0 && sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config${RESET}"
                fi
            else
                ok "SELinux: ${SELINUX_STATUS}"
            fi

            # firewalld
            if systemctl is-active firewalld &>/dev/null; then
                warn "firewalld 正在运行 — K8s 网络可能受影响"
                if $APPLY; then
                    systemctl stop firewalld && systemctl disable firewalld && \
                        changed "已停止并禁用 firewalld"
                elif $DRY_RUN; then
                    echo -e "  ${DIM}[DRY-RUN] systemctl stop firewalld && systemctl disable firewalld${RESET}"
                fi
            else
                ok "firewalld 未运行 ✓"
            fi

            # NetworkManager
            if systemctl is-active NetworkManager &>/dev/null; then
                warn "NetworkManager 运行中 — 可能干扰 K8s 网络，建议禁用"
                if $APPLY; then
                    systemctl stop NetworkManager && systemctl disable NetworkManager && \
                        changed "已禁用 NetworkManager"
                fi
            fi

            # 时间同步
            if ! systemctl is-active chronyd &>/dev/null && ! systemctl is-active ntpd &>/dev/null; then
                warn "时间同步服务未运行（chrony/ntpd）"
                if $APPLY; then
                    yum install -y chrony &>/dev/null && \
                    systemctl enable chronyd && systemctl start chronyd && \
                        changed "已安装并启动 chronyd"
                fi
            else
                ok "时间同步服务运行中"
            fi

            # 必要工具
            section "CentOS 7 必要工具安装"
            TOOLS_YUM=("ipset" "ipvsadm" "socat" "conntrack-tools" "sysstat" "iotop" "net-tools")
            for tool in "${TOOLS_YUM[@]}"; do
                if ! command -v "${tool%%-*}" &>/dev/null && ! rpm -q "${tool}" &>/dev/null; then
                    warn "工具 ${tool} 未安装"
                    $APPLY && yum install -y "${tool}" &>/dev/null && changed "已安装 ${tool}" || true
                else
                    ok "工具 ${tool} 已安装"
                fi
            done
        fi
        ;;

    # ──────────────────────────────────────────
    # Rocky / AlmaLinux 8/9
    # ──────────────────────────────────────────
    rocky|almalinux|rhel)
        section "Rocky/AlmaLinux ${OS_VER} 专项优化"

        # SELinux
        SELINUX_STATUS=$(getenforce 2>/dev/null || echo "unknown")
        info "SELinux 状态: ${SELINUX_STATUS}"
        if [[ "${SELINUX_STATUS}" == "Enforcing" ]]; then
            warn "SELinux Enforcing"
            if $APPLY; then
                setenforce 0
                sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
                changed "SELinux 设为 Permissive"
            fi
        else
            ok "SELinux: ${SELINUX_STATUS}"
        fi

        # firewalld
        if systemctl is-active firewalld &>/dev/null; then
            warn "firewalld 运行中"
            $APPLY && systemctl stop firewalld && systemctl disable firewalld && changed "已禁用 firewalld"
        else
            ok "firewalld 未运行"
        fi

        # 工具
        TOOLS_DNF=("ipset" "ipvsadm" "socat" "conntrack-tools" "sysstat" "iotop")
        for tool in "${TOOLS_DNF[@]}"; do
            if ! rpm -q "${tool}" &>/dev/null; then
                warn "工具 ${tool} 未安装"
                $APPLY && dnf install -y "${tool}" &>/dev/null && changed "已安装 ${tool}" || true
            else
                ok "工具 ${tool} 已安装"
            fi
        done

        # crypto-policy（RHEL 9）
        if [[ "${OS_VER}" -ge 9 ]]; then
            section "RHEL 9 加密策略"
            CRYPTO=$(update-crypto-policies --show 2>/dev/null || echo "unknown")
            info "当前加密策略: ${CRYPTO}"
            if [[ "${CRYPTO}" == "FUTURE" ]]; then
                warn "加密策略 FUTURE 可能导致部分服务连接失败，建议改为 DEFAULT"
                $APPLY && update-crypto-policies --set DEFAULT && changed "加密策略已设为 DEFAULT"
            fi
        fi
        ;;

    # ──────────────────────────────────────────
    # Ubuntu / Debian
    # ──────────────────────────────────────────
    ubuntu|debian)
        section "Ubuntu/Debian 专项优化"

        # ufw
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
            warn "ufw 防火墙激活，可能影响 K8s 网络"
            if $APPLY; then
                ufw disable && changed "已禁用 ufw"
            elif $DRY_RUN; then
                echo -e "  ${DIM}[DRY-RUN] ufw disable${RESET}"
            fi
        else
            ok "ufw 未激活"
        fi

        # apparmor
        if systemctl is-active apparmor &>/dev/null; then
            info "AppArmor 运行中（Ubuntu 默认，containerd 已适配，通常无需关闭）"
            ok "AppArmor 状态正常"
        fi

        # 必要工具
        TOOLS_APT=("ipset" "ipvsadm" "socat" "conntrack" "sysstat" "iotop" "net-tools")
        for tool in "${TOOLS_APT[@]}"; do
            if ! dpkg -l "${tool}" &>/dev/null 2>&1 | grep -q '^ii'; then
                warn "工具 ${tool} 未安装"
                if $APPLY; then
                    apt-get install -y "${tool}" &>/dev/null && changed "已安装 ${tool}" || true
                fi
            else
                ok "工具 ${tool} 已安装"
            fi
        done

        # 时区
        TZ_NOW=$(timedatectl 2>/dev/null | grep 'Time zone' | awk '{print $3}')
        if [[ "${TZ_NOW}" != "Asia/Shanghai" ]]; then
            warn "时区: ${TZ_NOW}，建议设为 Asia/Shanghai"
            $APPLY && timedatectl set-timezone Asia/Shanghai && changed "时区已设为 Asia/Shanghai"
        else
            ok "时区: ${TZ_NOW}"
        fi

        # 禁用 systemd-resolved（可能干扰 CoreDNS）
        if systemctl is-active systemd-resolved &>/dev/null; then
            info "systemd-resolved 运行中（如 CoreDNS 解析异常可考虑禁用）"
        fi
        ;;
esac

# ══════════════════════════════════════════════
# 七、透明大页（THP）
# ══════════════════════════════════════════════
header "七、透明大页（THP）"

section "7.1 THP 状态检查"
THP_FILE="/sys/kernel/mm/transparent_hugepage/enabled"
if [[ -f "${THP_FILE}" ]]; then
    THP_STATUS=$(cat "${THP_FILE}")
    info "THP 状态: ${THP_STATUS}"
    if echo "${THP_STATUS}" | grep -q '\[always\]'; then
        warn "THP 为 always — Redis/MongoDB/Elasticsearch 等中间件会受影响（延迟抖动）"
        if $APPLY; then
            echo never > "${THP_FILE}"
            echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
            changed "THP 已设为 never"
            # 持久化
            cat > /etc/rc.d/rc.local 2>/dev/null << 'EOF' || true
#!/bin/bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
EOF
            chmod +x /etc/rc.d/rc.local 2>/dev/null || true
        elif $DRY_RUN; then
            echo -e "  ${DIM}[DRY-RUN] echo never > ${THP_FILE}${RESET}"
        fi
    elif echo "${THP_STATUS}" | grep -q '\[never\]'; then
        ok "THP 已设为 never ✓"
    else
        ok "THP: ${THP_STATUS}"
    fi

    # 通过 systemd 持久化 THP（更可靠）
    THP_SERVICE="/etc/systemd/system/disable-thp.service"
    if [[ ! -f "${THP_SERVICE}" ]]; then
        if $APPLY; then
            cat > "${THP_SERVICE}" << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled && echo never > /sys/kernel/mm/transparent_hugepage/defrag"
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
            systemctl daemon-reload
            systemctl enable disable-thp 2>/dev/null && changed "THP 禁用服务已配置（开机生效）"
        fi
    else
        ok "THP 禁用服务已配置"
    fi
fi

# ══════════════════════════════════════════════
# 八、CPU 调度器
# ══════════════════════════════════════════════
header "八、CPU 调度器优化"

section "8.1 CPU 频率调节器"
GOV_FILE="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
if [[ -f "${GOV_FILE}" ]]; then
    GOV=$(cat "${GOV_FILE}")
    info "当前调节器: ${GOV}"
    if [[ "${GOV}" != "performance" ]]; then
        warn "CPU 调节器 ${GOV} — 建议改为 performance（避免频率抖动影响延迟）"
        if $APPLY; then
            for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                echo performance > "${gov}" 2>/dev/null || true
            done
            changed "CPU 调节器已设为 performance"

            # 持久化（不同发行版方式不同）
            case "${OS_ID}" in
                centos|rhel|rocky|almalinux)
                    $PKG_MGR install -y cpupower &>/dev/null || true
                    echo 'GOVERNOR="performance"' > /etc/sysconfig/cpupower 2>/dev/null || true
                    systemctl enable cpupower 2>/dev/null || true
                    ;;
                ubuntu|debian)
                    apt-get install -y cpufrequtils &>/dev/null || true
                    echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils 2>/dev/null || true
                    ;;
            esac
        elif $DRY_RUN; then
            echo -e "  ${DIM}[DRY-RUN] echo performance > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor${RESET}"
        fi
    else
        ok "CPU 调节器: performance ✓"
    fi
else
    info "cpufreq 不可用（虚拟化环境或内核无此功能）"
fi

section "8.2 NUMA 均衡"
NUMA_BAL=$(cat /proc/sys/kernel/numa_balancing 2>/dev/null || echo "N/A")
info "NUMA 自动均衡: ${NUMA_BAL}"
if [[ "${NUMA_BAL}" == "1" ]]; then
    warn "NUMA 自动均衡开启 — 在多 NUMA 节点上可能导致性能抖动"
    check_and_set "kernel.numa_balancing" "0" "禁用 NUMA 自动均衡"
fi

# ══════════════════════════════════════════════
# 九、汇总报告
# ══════════════════════════════════════════════
header "优化汇总"
echo ""
echo -e "  ${BOLD}参数检查总计:${RESET} $(( CHANGED_PARAMS + ALREADY_OK + SKIPPED ))"
echo -e "  ${GREEN}${BOLD}✓ 已达标:${RESET}  ${ALREADY_OK}"
echo -e "  ${CYAN}${BOLD}→ 已修改:${RESET}  ${CHANGED_PARAMS}"
echo -e "  ${DIM}⊘ 已跳过:${RESET}  ${SKIPPED}"
echo ""

if $CHECK_ONLY; then
    echo -e "  ${YELLOW}${BOLD}运行模式: CHECK-ONLY，以上均为检查结果，未做任何修改${RESET}"
    echo -e "  执行 ${BOLD}bash $0${RESET} 应用所有优化"
elif $DRY_RUN; then
    echo -e "  ${YELLOW}${BOLD}运行模式: DRY-RUN，未做实际修改${RESET}"
    echo -e "  执行 ${BOLD}sudo bash $0${RESET} 应用所有优化"
else
    echo -e "  ${GREEN}${BOLD}优化已应用！建议执行以下验证：${RESET}"
    echo ""
    echo -e "  ${CYAN}# 验证 sysctl 参数${RESET}"
    echo -e "  sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables vm.swappiness"
    echo ""
    echo -e "  ${CYAN}# 验证内核模块${RESET}"
    echo -e "  lsmod | grep -E 'overlay|br_netfilter|ip_vs|nf_conntrack'"
    echo ""
    echo -e "  ${CYAN}# 验证 Swap${RESET}"
    echo -e "  swapon --show"
    echo ""
    echo -e "  ${YELLOW}${BOLD}⚠ 部分参数需重启节点后生效（limits / 新内核）${RESET}"
fi

echo ""
echo -e "  ${BLUE}配置文件位置:${RESET}"
echo -e "  sysctl  : ${SYSCTL_CONF}"
echo -e "  limits  : ${LIMITS_CONF:-/etc/security/limits.d/99-k8s-wishfox.conf}"
echo -e "  modules : /etc/modules-load.d/k8s.conf"
echo ""



