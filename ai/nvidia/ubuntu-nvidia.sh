#!/usr/bin/env bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/ai/nvidia/ubuntu-nvidia.sh
# ================================================================
#  Ubuntu NVIDIA 驱动 + CUDA 安装脚本
#  支持: Ubuntu 20.04 / 22.04 / 24.04 (x86_64)
#  驱动: Ubuntu 官方仓库(ubuntu-drivers 自动选推荐版本)
#  CUDA: NVIDIA 官方 network repo(apt 源,可选只装 toolkit)
#  nvidia-container-toolkit: 走 Nexus raw-nvidia 代理
#
#  用法:
#    sudo bash ubuntu-nvidia.sh                      # 驱动 + CUDA toolkit
#    sudo bash ubuntu-nvidia.sh --driver-only        # 只装驱动
#    sudo bash ubuntu-nvidia.sh --cuda-only          # 只装 CUDA(驱动已装)
#    sudo bash ubuntu-nvidia.sh --driver 570         # 指定驱动版本系列
#    sudo bash ubuntu-nvidia.sh --cuda 12-6          # 指定 CUDA 版本(默认 12-6)
#    sudo bash ubuntu-nvidia.sh --uninstall          # 卸载驱动 + CUDA
#    sudo bash ubuntu-nvidia.sh --no-toolkit         # 不装 nvidia-container-toolkit
# ================================================================
set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

NEXUS="${NEXUS:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-nvidia}"
CUDA_REPO_BASE="${CUDA_REPO_BASE:-https://developer.download.nvidia.com/compute/cuda/repos}"
CUDA_VERSION="12-6"
DRIVER_SERIES=""
ONLY_DRIVER=false
ONLY_CUDA=false
DO_UNINSTALL=false
NO_TOOLKIT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --driver)      DRIVER_SERIES="$2"; shift 2 ;;
    --cuda)        CUDA_VERSION="$2"; shift 2 ;;
    --driver-only) ONLY_DRIVER=true; shift ;;
    --cuda-only)   ONLY_CUDA=true; shift ;;
    --no-toolkit)  NO_TOOLKIT=true; shift ;;
    --uninstall)   DO_UNINSTALL=true; shift ;;
    -h|--help)     sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
title() { echo -e "\n${CYAN}${BOLD}━━━  $1  ━━━${NC}"; }

[ "$(id -u)" = "0" ] || err "需要 root 或 sudo 执行"

. /etc/os-release
[[ "$ID" == "ubuntu" ]] || err "此脚本只支持 Ubuntu(当前: ${ID})"
case "$VERSION_ID" in
  20.04|22.04|24.04) info "系统: Ubuntu ${VERSION_ID} $(uname -m)" ;;
  *) err "不支持的 Ubuntu 版本: ${VERSION_ID}(支持 20.04/22.04/24.04)" ;;
esac
[[ "$(uname -m)" == "x86_64" ]] || err "只支持 x86_64(arm64 CUDA repo 路径不同,需另行适配)"

# 检测显卡(至少要 lspci 或已有 nvidia-smi 能看到)
GPU=$(lspci 2>/dev/null | grep -i nvidia | head -1 || true)
if [ -z "$GPU" ] && command -v nvidia-smi &>/dev/null; then
  GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
fi
[ -n "$GPU" ] || err "未检测到 NVIDIA 显卡(lspci 需要 pciutils 包)"
info "检测到: ${GPU}"

# ================================================================
# 卸载
# ================================================================
if [ "$DO_UNINSTALL" = true ]; then
  title "卸载 NVIDIA 驱动 + CUDA"
  warn "黑屏无法进系统时: GRUB → Recovery mode → root shell 执行本脚本 --uninstall"
  echo ""
  apt-get purge -y 'nvidia-*' 'libnvidia-*' 'cuda-*' 'nvidia-cuda-toolkit*' 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/cuda*.list \
        /usr/share/keyrings/cuda-archive-keyring.gpg \
        /etc/apt/sources.list.d/nvidia-container-toolkit.list \
        /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  rm -f /etc/modprobe.d/nvidia*.conf /etc/modules-load.d/nvidia*.conf
  apt-get update -qq
  info "已卸载并清理 apt 源,重启生效: reboot"
  exit 0
fi

# ================================================================
# 依赖 + 禁 nouveau
# ================================================================
prepare_env() {
  title "环境准备"
  apt-get update -qq
  apt-get install -y -qq pciutils build-essential dkms linux-headers-$(uname -r) >/dev/null
  info "编译依赖已就绪(gcc / dkms / linux-headers-$(uname -r))"

  # blacklist nouveau(驱动包通常自带,这里兜底确保)
  if ! lsmod | grep -q '^nouveau'; then
    info "nouveau 未加载,跳过 blacklist"
  elif [ ! -f /etc/modprobe.d/blacklist-nouveau.conf ]; then
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    update-initramfs -u >/dev/null 2>&1
    warn "nouveau 已 blacklist,需要重启后 nouveau 才会真正卸载"
    NEED_REBOOT=true
  else
    info "nouveau blacklist 已存在"
  fi
}

# ================================================================
# 驱动
# ================================================================
install_driver() {
  title "安装 NVIDIA 驱动"

  if command -v nvidia-smi &>/dev/null; then
    info "驱动已安装: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    if [ -z "$DRIVER_SERIES" ]; then
      info "未指定 --driver,跳过重装"
      return
    fi
    warn "指定了 --driver ${DRIVER_SERIES},继续重装"
  fi

  apt-get install -y -qq ubuntu-drivers-common >/dev/null
  if [ -z "$DRIVER_SERIES" ]; then
    # 自动选 ubuntu-drivers 推荐版本
    DRIVER_SERIES=$(ubuntu-drivers devices 2>/dev/null | grep "recommended" | grep -oP "nvidia-driver-\K\d+" | head -1 || true)
    if [ -n "$DRIVER_SERIES" ]; then
      info "ubuntu-drivers 推荐版本: nvidia-driver-${DRIVER_SERIES}"
    else
      DRIVER_SERIES=570
      warn "无法获取推荐版本,兜底安装 nvidia-driver-570"
    fi
  fi

  info "安装 nvidia-driver-${DRIVER_SERIES}..."
  apt-get install -y nvidia-driver-${DRIVER_SERIES}
  modprobe nvidia 2>/dev/null && info "nvidia 模块已加载" || warn "模块未能立即加载,重启后生效"
}

# ================================================================
# CUDA network repo + toolkit
# ================================================================
install_cuda() {
  title "安装 CUDA ${CUDA_VERSION/-/.} (network repo)"

  local PIN_FILE="/etc/apt/preferences.d/cuda-repository-pin-600"
  [ -f "$PIN_FILE" ] || cat > "$PIN_FILE" << 'EOF'
Package: nsight-compute
Pin: origin developer.download.nvidia.com
Pin-Priority: -1
EOF

  # ubuntu2004/2204/2404 是 NVIDIA repo 的目录名(20.04 之后未再细分,复用 2204)
  local DIST
  case "$VERSION_ID" in
    20.04) DIST="ubuntu2004" ;;
    *)     DIST="ubuntu2204" ;;
  esac

  # CUDA network repo 直连 developer.download.nvidia.com(国内一般可达;
  # 若节点拉不动,设 CUDA_REPO_BASE 走代理覆盖,如 chfs 中转)
  local KEYRING="/usr/share/keyrings/cuda-archive-keyring.gpg"
  info "拉 CUDA repo key..."
  curl -fsSL "${CUDA_REPO_BASE}/${DIST}/cuda-archive-keyring.gpg" -o "$KEYRING"

  echo "deb [signed-by=${KEYRING}] ${CUDA_REPO_BASE}/${DIST}/ /" \
    > /etc/apt/sources.list.d/cuda.list

  apt-get update -qq
  info "安装 cuda-toolkit-${CUDA_VERSION}(不含驱动,驱动由 ubuntu 仓库管理)..."
  apt-get install -y cuda-toolkit-${CUDA_VERSION}
  info "CUDA 安装完成: /usr/local/cuda-${CUDA_VERSION/-/.}"
}

# ================================================================
# nvidia-container-toolkit(走 Nexus)
# ================================================================
install_toolkit() {
  title "安装 nvidia-container-toolkit (Nexus 代理)"
  local KEYRING="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  local LIST_FILE="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

  curl -fsSL "${NEXUS}/libnvidia-container/gpgkey" \
    | gpg --dearmor --yes -o "${KEYRING}"
  curl -fsSL "${NEXUS}/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
    | sed -e "s#https://nvidia.github.io/libnvidia-container/#${NEXUS}/libnvidia-container/#g" \
          -e "s#^deb #deb [signed-by=${KEYRING}] #" \
    > "${LIST_FILE}"
  apt-get update -qq
  apt-get install -y nvidia-container-toolkit

  # 配 runtime(有哪个配哪个)
  if command -v nvidia-ctk &>/dev/null; then
    if command -v docker &>/dev/null; then
      nvidia-ctk runtime configure --runtime=docker
      systemctl restart docker
      info "docker runtime 已配置"
    fi
    if [ -f /etc/containerd/config.toml ]; then
      nvidia-ctk runtime configure --runtime=containerd
      systemctl restart containerd
      info "containerd runtime 已配置"
    fi
  fi
}

# ================================================================
# 主流程
# ================================================================
NEED_REBOOT=false
prepare_env

if [ "$ONLY_CUDA" != true ]; then
  install_driver
fi
if [ "$ONLY_DRIVER" != true ]; then
  install_cuda
fi
if [ "$NO_TOOLKIT" != true ]; then
  install_toolkit
fi

# ================================================================
# 验证 + 提示
# ================================================================
title "完成"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  info "驱动: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
else
  warn "nvidia-smi 不可用,重启后生效: reboot"
  NEED_REBOOT=true
fi
[ -x /usr/local/cuda/bin/nvcc ] && info "CUDA: $(/usr/local/cuda/bin/nvcc --version | tail -1 | grep -oP 'release \K[0-9.]+')"
echo ""
echo "验证命令:"
echo "  nvidia-smi"
echo "  /usr/local/cuda/bin/nvcc --version"
echo "  docker run --rm --gpus all ubuntu:22.04 nvidia-smi   # 需要 toolkit + runtime 已配"
[ "$NEED_REBOOT" = true ] && echo "" && warn "存在待重启项(reboot 后重新跑一次本脚本可验证)"
exit 0
