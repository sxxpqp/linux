#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/nvidia/nvidia-driver-install.sh
# NVIDIA 显卡驱动自动安装脚本（跨平台）
# 自动检测系统和显卡，优先用系统包管理器安装最新兼容驱动
#
# 用法:
#   bash nvidia-driver-install.sh
#   curl -sL <URL> | bash
#   bash nvidia-driver-install.sh --nvidia-toolkit  # 只装容器工具
#   bash nvidia-driver-install.sh --driver          # 只装驱动

set -u
ONLY_TOOLKIT=false
ONLY_DRIVER=false
while [ $# -gt 0 ]; do
  case "$1" in
    --nvidia-toolkit) ONLY_TOOLKIT=true; shift ;;
    --driver) ONLY_DRIVER=true; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# Color
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }

# ---- 检测系统 ----
. /etc/os-release 2>/dev/null || { err "无法检测系统"; exit 1; }
info "系统: ${ID} ${VERSION_ID} 架构: $(uname -m)"

# ---- 检测显卡 ----
GPU=$(lspci 2>/dev/null | grep -i nvidia | head -1 || true)
if [ -n "$GPU" ]; then
  info "检测到: ${GPU}"
else
  warn "lspci 未找到 NVIDIA 设备，尝试 nvidia-smi..."
  if command -v nvidia-smi &>/dev/null; then
    GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
    info "检测到: ${GPU}"
  else
    err "未检测到 NVIDIA 显卡（lspci 需 pciutils 包）"
    exit 1
  fi
fi

# ================================================================
# 安装驱动
# ================================================================
install_driver() {
  info "开始安装 NVIDIA 驱动..."

  case "${ID}" in
    ubuntu|debian)
      apt update -qq
      apt install -y ubuntu-drivers-common pciutils
      info "检测推荐驱动版本..."
      ubuntu-drivers devices
      echo ""
      # 自动安装推荐版本
      ubuntu-drivers autoinstall || {
        warn "ubuntu-drivers 自动安装失败，尝试手动安装..."
        RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | grep "recommended" | grep -oP "nvidia-driver-\d+" | head -1)
        if [ -n "$RECOMMENDED" ]; then
          apt install -y "$RECOMMENDED"
        else
          apt install -y nvidia-driver-550
        fi
      }
      # 尝试加载驱动模块，避免必须重启
      modprobe nvidia 2>/dev/null || true
      modprobe nvidia_uvm 2>/dev/null || true
      ;;

    centos|rhel|rocky|almalinux)
      yum install -y epel-release
      rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
      yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm
      yum --enablerepo=elrepo install -y kmod-nvidia
      ;;

    *)
      err "不支持的发行版: ${ID}"
      exit 1
      ;;
  esac
}

# ================================================================
# 安装 nvidia-container-toolkit
# ================================================================
install_toolkit() {
  info "安装 nvidia-container-toolkit..."

  case "${ID}" in
    ubuntu|debian)
      local NEXUS="https://nexus.ihome.sxxpqp.top:8443/repository/raw-nvidia"
      local KEYRING="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
      local LIST_FILE="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

      # GPG key
      curl -fsSL "${NEXUS}/libnvidia-container/gpgkey" | gpg --dearmor --yes -o "${KEYRING}" 2>/dev/null || true

      # apt 源（从 Nexus 拉官方 list 并重写 URL）
      curl -sL "${NEXUS}/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
        | sed -e "s#https://nvidia.github.io/libnvidia-container/#${NEXUS}/libnvidia-container/#g" \
              -e "s#^deb #deb [signed-by=${KEYRING}] #" \
        | tee "${LIST_FILE}" >/dev/null

      apt update -qq
      apt install -y nvidia-container-toolkit
      ;;

    centos|rhel|rocky|almalinux)
      local REPO_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-nvidia/nvidia-docker/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo"
      curl -s -L "$REPO_URL" -o /etc/yum.repos.d/nvidia-container-toolkit.repo
      yum install -y nvidia-container-toolkit
      ;;
  esac

  # 配置容器运行时
  if command -v docker &>/dev/null; then
    nvidia-ctk runtime configure --runtime=docker 2>/dev/null || true
    systemctl restart docker 2>/dev/null || true
    info "Docker 已配置 GPU 支持"
  fi
  if [ -f /etc/containerd/config.toml ]; then
    nvidia-ctk runtime configure --runtime=containerd 2>/dev/null || true
    systemctl restart containerd 2>/dev/null || true
    info "Containerd 已配置 GPU 支持"
  fi
}

# ================================================================
# 执行
# ================================================================
if [ "$ONLY_TOOLKIT" = true ]; then
  install_toolkit
elif [ "$ONLY_DRIVER" = true ]; then
  install_driver
else
  install_driver
  install_toolkit
fi

# 验证
echo ""
if command -v nvidia-smi &>/dev/null; then
  info "驱动版本: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  echo ""
  echo " nvidia-smi  # 查看 GPU 状态"
  echo " docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi  # 验证 Docker GPU"
else
  warn "需要重启系统使驱动生效: reboot"
fi
