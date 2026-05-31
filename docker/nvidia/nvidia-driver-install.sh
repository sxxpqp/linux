#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/nvidia/nvidia-driver-install.sh
# NVIDIA 显卡驱动自动安装脚本（跨平台）
# 自动检测系统和显卡，优先用系统包管理器安装最新兼容驱动
#
# 用法:
#   bash nvidia-driver-install.sh                  # 安装
#   curl -sL <URL> | bash                          # 安装
#   bash nvidia-driver-install.sh --uninstall      # 卸载驱动
#   bash nvidia-driver-install.sh --nvidia-toolkit # 只装容器工具
#   bash nvidia-driver-install.sh --driver         # 只装驱动

set -u
ONLY_TOOLKIT=false
ONLY_DRIVER=false
DO_UNINSTALL=false
while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall) DO_UNINSTALL=true; shift ;;
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
# 环境准备：GCC + nomodeset
# ================================================================
prepare_env() {
  info "检查编译环境..."

  # 获取内核编译用的 GCC 版本
  local KERNEL_GCC_VER=$(cat /proc/version 2>/dev/null | grep -oP 'gcc[^0-9]*\K[0-9]+\.[0-9]+' | head -1 || echo "")
  local SYS_GCC_VER=$(gcc -dumpversion 2>/dev/null || echo "")
  local KERNEL_GCC_MAJOR=${KERNEL_GCC_VER%%.*}
  local SYS_GCC_MAJOR=${SYS_GCC_VER%%.*}

  case "${ID}" in
    ubuntu|debian)
      apt update -qq
      if ! command -v gcc &>/dev/null || ! ls /lib/modules/$(uname -r)/build &>/dev/null; then
        warn "安装 GCC + 内核头文件 (linux-headers-$(uname -r))..."
        apt install -y build-essential linux-headers-$(uname -r)
        SYS_GCC_VER=$(gcc -dumpversion 2>/dev/null || echo "")
        SYS_GCC_MAJOR=${SYS_GCC_VER%%.*}
      fi

      # GCC 版本不匹配则提示（非致命）
      if [ -n "$KERNEL_GCC_MAJOR" ] && [ -n "$SYS_GCC_MAJOR" ] && [ "$KERNEL_GCC_MAJOR" != "$SYS_GCC_MAJOR" ]; then
        warn "内核编译用 GCC ${KERNEL_GCC_VER}，系统当前 GCC ${SYS_GCC_VER}"
        warn "建议安装匹配版本: apt install -y gcc-${KERNEL_GCC_MAJOR}"
      fi
      ;;
    centos|rhel|rocky|almalinux)
      if ! command -v gcc &>/dev/null || ! rpm -q kernel-devel &>/dev/null; then
        warn "安装 GCC + kernel-devel..."
        yum install -y gcc kernel-devel kernel-headers
        SYS_GCC_VER=$(gcc -dumpversion 2>/dev/null || echo "")
        SYS_GCC_MAJOR=${SYS_GCC_VER%%.*}
      fi

      if [ -n "$KERNEL_GCC_MAJOR" ] && [ -n "$SYS_GCC_MAJOR" ] && [ "$KERNEL_GCC_MAJOR" != "$SYS_GCC_MAJOR" ]; then
        warn "内核编译用 GCC ${KERNEL_GCC_VER}，系统当前 GCC ${SYS_GCC_VER}"
        warn "建议安装匹配版本: yum install -y gcc-${KERNEL_GCC_MAJOR}"
      fi
      ;;
  esac

  info "GCC: $(gcc --version 2>/dev/null | head -1)"
  info "内核头: 匹配 $(uname -r)"

  info "配置 nomodeset（禁用 noveau，避免驱动冲突）..."
  local GRUB_FILE="/etc/default/grub"
  if [ -f "$GRUB_FILE" ]; then
    if grep -q "nomodeset" "$GRUB_FILE"; then
      info "nomodeset 已配置"
    else
      sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nomodeset /' "$GRUB_FILE"
      info "已添加 nomodeset 到 GRUB"

      case "${ID}" in
        ubuntu|debian) update-grub ;;
        centos|rhel|rocky|almalinux) grub2-mkconfig -o /boot/grub2/grub.cfg ;;
      esac
      info "GRUB 已更新，重启后生效"
    fi
  else
    warn "未找到 ${GRUB_FILE}，跳过 nomodeset 配置"
  fi
}

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

      # 优先装 @recommended 标记的版本
      RECOMMENDED=$(ubuntu-drivers devices 2>/dev/null | grep "recommended" | grep -oP "nvidia-driver-\d+" | head -1)

      if [ -n "$RECOMMENDED" ]; then
        info "安装推荐版本: ${RECOMMENDED}"
        apt install -y "$RECOMMENDED"
      else
        # 无推荐时根据显卡架构选合适的驱动系列
        GPU_MODEL=$(echo "$GPU" | tr '[:upper:]' '[:lower:]')
        if echo "$GPU_MODEL" | grep -qE 'rtx 50[0-9]0|blackwell|5080|5090|5070'; then
          info "RTX 50 系列，安装 nvidia-driver-570"
          apt install -y nvidia-driver-570
        elif echo "$GPU_MODEL" | grep -qE 'rtx 40[0-9]0|ada|4080|4090|4070|4060'; then
          info "RTX 40 系列，安装 nvidia-driver-550"
          apt install -y nvidia-driver-550
        else
          info "未知架构，安装最新可用驱动..."
          apt install -y nvidia-driver-535
        fi
      fi
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
# 卸载驱动（黑屏恢复用）
# ================================================================
uninstall_driver() {
  warn "开始卸载 NVIDIA 驱动..."
  warn "如果已黑屏无法进入系统："
  warn "  1. 重启按住 Shift 进入 GRUB 菜单"
  warn "  2. 选 Advanced options → Recovery mode → root shell"
  warn "  3. 执行: bash <(curl -sL <本脚本URL>) --uninstall"
  warn "  4. 或者手动: mount -o rw,remount / && apt purge nvidia-* && update-grub && reboot"
  echo ""

  case "${ID}" in
    ubuntu|debian)
      apt purge -y nvidia-* cuda-* libnvidia-* 2>/dev/null || true
      apt autoremove -y 2>/dev/null || true
      # 清除 nvidia-container-toolkit
      apt purge -y nvidia-container-toolkit 2>/dev/null || true
      rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list 2>/dev/null || true
      rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
      ;;
    centos|rhel|rocky|almalinux)
      yum remove -y kmod-nvidia nvidia-* cuda-* libnvidia-* 2>/dev/null || true
      rm -f /etc/yum.repos.d/nvidia-container-toolkit.repo 2>/dev/null || true
      ;;
  esac

  # 清理 Blacklist 和 modprobe 配置
  rm -f /etc/modprobe.d/nvidia*.conf 2>/dev/null || true
  rm -f /etc/modules-load.d/nvidia*.conf 2>/dev/null || true

  # 移除 nomodeset（以防下次装其他显卡）
  local GRUB_FILE="/etc/default/grub"
  if [ -f "$GRUB_FILE" ] && grep -q "nomodeset" "$GRUB_FILE"; then
    sed -i 's/ nomodeset//g; s/nomodeset //g' "$GRUB_FILE"
    case "${ID}" in
      ubuntu|debian) update-grub ;;
      centos|rhel|rocky|almalinux) grub2-mkconfig -o /boot/grub2/grub.cfg ;;
    esac
    info "已移除 nomodeset"
  fi

  info "NVIDIA 驱动已卸载，重启即可恢复"
  echo ""
  echo "  reboot"
}

# ================================================================
# 执行
# ================================================================
if [ "$DO_UNINSTALL" = true ]; then
  uninstall_driver
elif [ "$ONLY_TOOLKIT" = true ]; then
  install_toolkit
elif [ "$ONLY_DRIVER" = true ]; then
  prepare_env
  install_driver
else
  prepare_env
  install_driver
  install_toolkit
fi

# 验证
echo ""
if [ "$DO_UNINSTALL" != true ]; then
  if command -v nvidia-smi &>/dev/null; then
    info "驱动版本: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
    echo ""
    echo " nvidia-smi  # 查看 GPU 状态"
    echo " docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi  # 验证 Docker GPU"
  else
    warn "需要重启系统使驱动生效: reboot"
  fi
fi
