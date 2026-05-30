#!/bin/bash
# ================================================================
#  K8s 组件安装脚本
#  作者: sxxpqp 运智运维
#  支持: CentOS 7/8/9, Rocky, AlmaLinux, Ubuntu 20.04/22.04/24.04
#  版本: 1.24 ~ 1.32
# ================================================================
set -euo pipefail

# ---- curl|bash 执行时 stdin 被管道占用，所有 read 显式从 /dev/tty 读取 ----
TTY_INPUT=/dev/tty

# ──────────────────────────────────────────────
# 全局配置（按需修改）
# ──────────────────────────────────────────────
REGISTRY="registry.aliyuncs.com/google_containers"
CONTROL_PLANE_ENDPOINT="172.16.0.49:6443"
POD_CIDR="10.244.0.0/16"
ALIYUN_MIRROR="https://mirrors.aliyun.com"

# ──────────────────────────────────────────────
# 颜色输出
# ──────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m';  BOLD='\033[1m';      RESET='\033[0m'
ok()    { echo -e "${GREEN}✓${RESET} $1"; }
warn()  { echo -e "${YELLOW}⚠${RESET} $1"; }
err()   { echo -e "${RED}✗${RESET} $1"; exit 1; }
info()  { echo -e "→ $1"; }
title() { echo -e "\n${CYAN}${BOLD}━━━  $1  ━━━${RESET}"; }

# ──────────────────────────────────────────────
# 必须 root
# ──────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "请使用 root 或 sudo 执行"

# ──────────────────────────────────────────────
# 检测操作系统
# ──────────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_ID="$ID"
        OS_VER="${VERSION_ID%%.*}"
    else
        err "无法识别操作系统"
    fi
    ok "操作系统: ${ID} ${VERSION_ID}"
}

# ──────────────────────────────────────────────
# 版本选择菜单
# ──────────────────────────────────────────────
select_version() {
    title "选择 Kubernetes 版本"

    # 支持的版本列表（1.24 开始，阿里云新源）
    VERSIONS=(
        "1.24"
        "1.25"
        "1.26"
        "1.27"
        "1.28"
        "1.29"
        "1.30"
        "1.31"
        "1.32"
        "1.33"
        "1.34"
        "1.35"
    )
    DEFAULT_CHOICE=5   # 默认 1.28

    echo -e "${BOLD}支持的版本:${RESET}"
    for i in "${!VERSIONS[@]}"; do
        MARK=""
        [[ "${VERSIONS[$i]}" == "1.28" ]] && MARK=" ${YELLOW}[默认推荐]${RESET}"
        [[ "${VERSIONS[$i]}" == "1.33" ]] && MARK=" ${CYAN}[当前维护]${RESET}"
        [[ "${VERSIONS[$i]}" == "1.34" ]] && MARK=" ${CYAN}[当前维护]${RESET}"
        [[ "${VERSIONS[$i]}" == "1.35" ]] && MARK=" ${CYAN}[最新稳定]${RESET}"
        echo -e "  $((i+1))) ${VERSIONS[$i]}${MARK}"
    done
    echo ""
    read -rp "请选择版本编号 [默认 ${DEFAULT_CHOICE} 即 1.28]: " choice < ${TTY_INPUT}
    choice="${choice:-${DEFAULT_CHOICE}}"

    # 验证输入
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || \
       [[ "$choice" -lt 1 ]] || \
       [[ "$choice" -gt "${#VERSIONS[@]}" ]]; then
        err "无效选择: $choice"
    fi

    K8S_MINOR="${VERSIONS[$((choice-1))]}"
    ok "已选择版本: ${K8S_MINOR}"

    # ---- 动态获取该小版本的最新补丁版本 ----
    info "查询 v${K8S_MINOR} 最新可用版本..."

    # 临时配置仓库后查询，不实际安装
    if command -v apt-get &>/dev/null; then
        # DEB: 临时添加源后 apt-cache 查询
        mkdir -p /etc/apt/keyrings
        curl -fsSL ${ALIYUN_MIRROR}/kubernetes-new/core/stable/v${K8S_MINOR}/deb/Release.key             | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes 2>/dev/null || true
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] ${ALIYUN_MIRROR}/kubernetes-new/core/stable/v${K8S_MINOR}/deb/ /"             > /etc/apt/sources.list.d/kubernetes.list
        apt-get update -qq 2>/dev/null || true

        # 获取最新可用版本
        LATEST_DEB=$(apt-cache madison kubelet 2>/dev/null |             grep "${K8S_MINOR}" | head -1 | awk '{print $3}' | tr -d ' ')

        if [[ -n "$LATEST_DEB" ]]; then
            K8S_VERSION_DEB="$LATEST_DEB"
            # 从 DEB 版本提取 RPM 版本 (1.28.15-1.1 → 1.28.15)
            K8S_VERSION_RPM="${LATEST_DEB%-*.*}"
            ok "动态获取版本: DEB=${K8S_VERSION_DEB}  RPM=${K8S_VERSION_RPM}"
        else
            warn "无法动态获取版本，使用内置默认值"
            _use_default_version
        fi

    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        # RPM: 临时配置 repo 后 yum list 查询
        cat > /tmp/k8s-query.repo << EOF
[kubernetes-query]
name=Kubernetes Query
baseurl=${ALIYUN_MIRROR}/kubernetes-new/core/stable/v${K8S_MINOR}/rpm/
enabled=1
gpgcheck=0
EOF
        PKG_CMD="yum"
        command -v dnf &>/dev/null && PKG_CMD="dnf"

        LATEST_RPM=$($PKG_CMD list available kubelet             --disablerepo="*"             --enablerepo="kubernetes-query"             --config=/tmp/k8s-query.repo             2>/dev/null | grep "^kubelet" |             grep "${K8S_MINOR}" | head -1 | awk '{print $2}' | cut -d: -f2 | cut -d- -f1)

        rm -f /tmp/k8s-query.repo

        if [[ -n "$LATEST_RPM" ]]; then
            K8S_VERSION_RPM="$LATEST_RPM"
            K8S_VERSION_DEB="${LATEST_RPM}-1.1"
            ok "动态获取版本: RPM=${K8S_VERSION_RPM}  DEB=${K8S_VERSION_DEB}"
        else
            warn "无法动态获取版本，使用内置默认值"
            _use_default_version
        fi
    else
        _use_default_version
    fi
}

# 内置默认版本（动态查询失败时的 fallback）
_use_default_version() {
    case "$K8S_MINOR" in
        "1.24") K8S_VERSION_RPM="1.24.17"; K8S_VERSION_DEB="1.24.17-1.1" ;;
        "1.25") K8S_VERSION_RPM="1.25.16"; K8S_VERSION_DEB="1.25.16-1.1" ;;
        "1.26") K8S_VERSION_RPM="1.26.15"; K8S_VERSION_DEB="1.26.15-1.1" ;;
        "1.27") K8S_VERSION_RPM="1.27.16"; K8S_VERSION_DEB="1.27.16-1.1" ;;
        "1.28") K8S_VERSION_RPM="1.28.15"; K8S_VERSION_DEB="1.28.15-1.1" ;;
        "1.29") K8S_VERSION_RPM="1.29.12"; K8S_VERSION_DEB="1.29.12-1.1" ;;
        "1.30") K8S_VERSION_RPM="1.30.8";  K8S_VERSION_DEB="1.30.8-1.1"  ;;
        "1.31") K8S_VERSION_RPM="1.31.4";  K8S_VERSION_DEB="1.31.4-1.1"  ;;
        "1.32") K8S_VERSION_RPM="1.32.4";  K8S_VERSION_DEB="1.32.4-1.1"  ;;
        "1.33") K8S_VERSION_RPM="1.33.0";  K8S_VERSION_DEB="1.33.0-1.1"  ;;
        "1.34") K8S_VERSION_RPM="1.34.0";  K8S_VERSION_DEB="1.34.0-1.1"  ;;
        "1.35") K8S_VERSION_RPM="1.35.3";  K8S_VERSION_DEB="1.35.3-1.1"  ;;
        *)      K8S_VERSION_RPM="1.28.15"; K8S_VERSION_DEB="1.28.15-1.1" ;;
    esac
    warn "使用内置版本: RPM=${K8S_VERSION_RPM}  DEB=${K8S_VERSION_DEB}"
}

# ══════════════════════════════════════════════
# 一、containerd 安装
# ══════════════════════════════════════════════
install_containerd() {
    title "安装 containerd"
    if command -v containerd &>/dev/null; then
        ok "containerd 已安装，跳过"
    else
        info "安装 containerd..."
        curl -fsSLk https://chfs.sxxpqp.top:8443/chfs/shared/docker/containerd/installcontainerd.sh | bash
        ok "containerd 安装完成"
    fi
}

# ══════════════════════════════════════════════
# 二、系统公共配置
# ══════════════════════════════════════════════
common_prepare() {
    title "系统基础配置"

    info "关闭 Swap..."
    swapoff -a
    sed -ri 's/^([^#].*swap.*)$/#\1/' /etc/fstab
    sysctl -w vm.swappiness=0
    ok "Swap 已关闭"

    info "设置 ulimit..."
    cat >> /etc/security/limits.conf << 'EOF'
# K8s 优化
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  unlimited
* hard nproc  unlimited
* soft memlock unlimited
* hard memlock unlimited
EOF
    ok "ulimit 已配置"

    info "加载内核模块..."
    modprobe overlay
    modprobe br_netfilter
    cat > /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
    ok "内核模块已加载"

    info "配置 sysctl..."
    cat > /etc/sysctl.d/k8s.conf << 'EOF'
# ── K8s 网络必需 ──────────────────────────────
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv6.conf.all.forwarding        = 1
net.ipv6.conf.all.disable_ipv6      = 0
net.ipv6.conf.default.disable_ipv6  = 0
net.ipv6.conf.lo.disable_ipv6       = 0

# ── 连接跟踪 ─────────────────────────────────
net.netfilter.nf_conntrack_max      = 2310720

# ── TCP 性能 ──────────────────────────────────
net.ipv4.tcp_keepalive_time         = 600
net.ipv4.tcp_keepalive_probes       = 3
net.ipv4.tcp_keepalive_intvl        = 15
net.ipv4.tcp_max_tw_buckets         = 36000
net.ipv4.tcp_tw_reuse               = 1
net.ipv4.tcp_max_orphans            = 327680
net.ipv4.tcp_orphan_retries         = 3
net.ipv4.tcp_syncookies             = 1
net.ipv4.tcp_max_syn_backlog        = 16384
net.ipv4.tcp_timestamps             = 0
net.core.somaxconn                  = 32768

# ── 文件系统 ──────────────────────────────────
fs.may_detach_mounts                = 1
fs.inotify.max_user_watches         = 1048576
fs.inotify.max_user_instances       = 8192
fs.file-max                         = 52706963
fs.nr_open                          = 52706963

# ── 内存 ─────────────────────────────────────
vm.overcommit_memory                = 1
vm.panic_on_oom                     = 0
EOF
    sysctl --system &>/dev/null
    ok "sysctl 已应用"
}

# ══════════════════════════════════════════════
# 三、CentOS/Rocky/AlmaLinux 安装 K8s
# ══════════════════════════════════════════════
install_k8s_rpm() {
    title "安装 K8s 组件（RPM）"

    info "配置 K8s yum 仓库（阿里云镜像 v${K8S_MINOR}）..."
    cat > /etc/yum.repos.d/kubernetes.repo << EOF
[kubernetes]
name=Kubernetes
baseurl=${ALIYUN_MIRROR}/kubernetes-new/core/stable/v${K8S_MINOR}/rpm/
enabled=1
gpgcheck=0
EOF

    # SELinux
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
        setenforce 0
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        ok "SELinux 设为 Permissive"
    fi

    # NetworkManager 兼容
    if systemctl is-active NetworkManager &>/dev/null; then
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/k8s.conf << 'EOF'
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan*;interface-name:cilium*
EOF
        systemctl restart NetworkManager
        ok "NetworkManager 已配置"
    fi

    info "安装依赖..."
    yum install -y ipvsadm ipset sysstat conntrack libseccomp

    info "安装 K8s 组件 v${K8S_VERSION_RPM}..."
    yum install -y --nogpgcheck \
        kubelet-${K8S_VERSION_RPM} \
        kubeadm-${K8S_VERSION_RPM} \
        kubectl-${K8S_VERSION_RPM}

    # 锁定版本
    yum versionlock add kubelet kubeadm kubectl 2>/dev/null || true

    systemctl enable --now kubelet
    ok "K8s 组件安装完成（RPM v${K8S_VERSION_RPM}）"
}

# ══════════════════════════════════════════════
# 四、Ubuntu/Debian 安装 K8s
# ══════════════════════════════════════════════
install_k8s_deb() {
    title "安装 K8s 组件（DEB）"

    info "安装依赖..."
    apt-get update -qq
    apt-get install -y apt-transport-https ca-certificates curl gpg \
        ipvsadm ipset sysstat conntrack libseccomp2

    if command -v kubelet &>/dev/null && \
       command -v kubeadm &>/dev/null && \
       command -v kubectl &>/dev/null; then
        INSTALLED=$(kubelet --version 2>/dev/null | awk '{print $2}' | tr -d 'v')
        if [[ "$INSTALLED" == "${K8S_VERSION_RPM}"* ]]; then
            ok "K8s 组件 v${K8S_VERSION_RPM} 已安装，跳过"
            return
        fi
        warn "已安装版本 ${INSTALLED}，将升级到 ${K8S_VERSION_DEB}"
        apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
    fi

    info "配置 K8s apt 仓库（阿里云镜像 v${K8S_MINOR}）..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL ${ALIYUN_MIRROR}/kubernetes-new/core/stable/v${K8S_MINOR}/deb/Release.key \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
${ALIYUN_MIRROR}/kubernetes-new/core/stable/v${K8S_MINOR}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list

    apt-get update -qq

    info "安装 K8s 组件 v${K8S_VERSION_DEB}..."
    apt-get install -y \
        kubelet=${K8S_VERSION_DEB} \
        kubeadm=${K8S_VERSION_DEB} \
        kubectl=${K8S_VERSION_DEB}

    # 锁定版本
    apt-mark hold kubelet kubeadm kubectl
    ok "版本已锁定，防止误升级"

    systemctl enable --now kubelet
    ok "K8s 组件安装完成（DEB v${K8S_VERSION_DEB}）"
}

# ══════════════════════════════════════════════
# 主流程
# ══════════════════════════════════════════════
detect_os
select_version
install_containerd
common_prepare

case "$OS_ID" in
    centos|rhel|rocky|almalinux)
        install_k8s_rpm
        ;;
    ubuntu|debian)
        install_k8s_deb
        ;;
    *)
        err "不支持的操作系统: $OS_ID"
        ;;
esac

# ══════════════════════════════════════════════
# 完成提示
# ══════════════════════════════════════════════
echo ""
ok "所有组件安装完成！"
echo ""
echo -e "${BOLD}下一步初始化 master 节点:${RESET}"
echo ""
echo "  # 使用 Cilium 替换 kube-proxy（推荐）"
echo "  kubeadm init \\"
echo "    --upload-certs \\"
echo "    --skip-phases=addon/kube-proxy \\"
echo "    --image-repository ${REGISTRY} \\"
echo "    --control-plane-endpoint ${CONTROL_PLANE_ENDPOINT} \\"
echo "    --kubernetes-version v${K8S_VERSION_RPM} \\"
echo "    --pod-network-cidr ${POD_CIDR}"
echo ""
echo -e "${YELLOW}说明: --skip-phases=addon/kube-proxy 跳过 kube-proxy 安装"
echo "      Cilium 以 kubeProxyReplacement=true 模式接管所有流量转发${RESET}"
echo ""
echo -e "${YELLOW}提示: worker 节点只需运行此脚本，然后执行 kubeadm join 命令${RESET}"
echo ""