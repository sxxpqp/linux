#!/usr/bin/env bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/ai/nvidia/ubuntu-nvidia-bin.sh
# ================================================================
#  Ubuntu NVIDIA 驱动 + CUDA 二进制安装脚本(.run 方式,不走 apt 装驱动/CUDA)
#
#  支持: Ubuntu 20.04 / 22.04 / 24.04 (x86_64)
#  驱动: NVIDIA-Linux-x86_64-<ver>.run   ← us.download.nvidia.com(或 --local-driver)
#  CUDA: cuda_<ver>_linux.run            ← developer.download.nvidia.com(或 --local-cuda)
#  toolkit: apt 走 Nexus raw-nvidia(官方无 .run 包,只能 apt)
#
#  内核模块开源/闭源:
#    --kernel-open   开源内核模块(Turing+ 推荐,DP/nvidia-open 方向)
#    默认闭源        传统 proprietary 模块(老卡 / 求稳)
#    两者都支持 --dkms,内核升级自动重编
#
#  驱动 ↔ CUDA 版本对齐:
#    CUDA 有最低驱动要求,脚本内置校验表,不满足直接报错。
#    CUDA toolkit 本身不带驱动(--no-opengl-libs --toolkit),驱动单独用 .run 装。
#
#  用法:
#    sudo bash ubuntu-nvidia-bin.sh                          # 驱动(闭源)+ CUDA
#    sudo bash ubuntu-nvidia-bin.sh --kernel-open            # 开源内核模块
#    sudo bash ubuntu-nvidia-bin.sh --driver 570.153.02 --cuda 12.6.3
#    sudo bash ubuntu-nvidia-bin.sh --driver-only            # 只装驱动
#    sudo bash ubuntu-nvidia-bin.sh --cuda-only              # 只装 CUDA(驱动已装)
#    sudo bash ubuntu-nvidia-bin.sh --local-driver ./NVIDIA-Linux-x86_64-570.153.02.run \
#                                    --local-cuda ./cuda_12.6.3_linux.run    # 离线(chfs 中转)
#    sudo bash ubuntu-nvidia-bin.sh --uninstall              # 卸载
#    sudo bash ubuntu-nvidia-bin.sh --no-toolkit             # 不装 nvidia-container-toolkit
# ================================================================
set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''
export DEBIAN_FRONTEND=noninteractive

# 可被环境覆盖的下载源(国内拉不动时:先下载到 chfs,再用 --local-* 装本地文件)
NVIDIA_DL_BASE="${NVIDIA_DL_BASE:-https://us.download.nvidia.com/XFree86/Linux-x86_64}"
CUDA_DL_BASE="${CUDA_DL_BASE:-https://developer.download.nvidia.com/compute/cuda}"
NEXUS="${NEXUS:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-nvidia}"

DEFAULT_DRIVER_VER="570.153.02"
DEFAULT_CUDA_VER="12.6.3"

DRIVER_VER=""
CUDA_VER=""
LOCAL_DRIVER=""
LOCAL_CUDA=""
KERNEL_OPEN=false
ONLY_DRIVER=false
ONLY_CUDA=false
NO_TOOLKIT=false
DO_UNINSTALL=false

while [ $# -gt 0 ]; do
  case "$1" in
    --driver)       DRIVER_VER="$2"; shift 2 ;;
    --cuda)         CUDA_VER="$2"; shift 2 ;;
    --local-driver) LOCAL_DRIVER="$2"; shift 2 ;;
    --local-cuda)   LOCAL_CUDA="$2"; shift 2 ;;
    --kernel-open)  KERNEL_OPEN=true; shift ;;
    --driver-only)  ONLY_DRIVER=true; shift ;;
    --cuda-only)    ONLY_CUDA=true; shift ;;
    --no-toolkit)   NO_TOOLKIT=true; shift ;;
    --uninstall)    DO_UNINSTALL=true; shift ;;
    -h|--help)      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  20.04|22.04|24.04) info "系统: Ubuntu ${VERSION_ID} $(uname -r) $(uname -m)" ;;
  *) err "不支持的 Ubuntu 版本: ${VERSION_ID}(支持 20.04/22.04/24.04)" ;;
esac
[[ "$(uname -m)" == "x86_64" ]] || err "只支持 x86_64(.run 包路径按架构区分)"

# ================================================================
# 驱动 ↔ CUDA 最低版本校验
#   CUDA 对驱动的要求(每代 CUDA 的 minimum driver version, Linux):
#   官方对照: https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/
#   只列本脚本常用版本,不在表内的 CUDA 版本要求用户 --driver 显式指定并自担对齐
# ================================================================
# CUDA 主.次 → 最低驱动版本
cuda_min_driver() {
  case "$1" in
    12.0) echo 525.60.13  ;;
    12.1) echo 530.30.02  ;;
    12.2) echo 535.54.03  ;;
    12.3) echo 545.23.08  ;;
    12.4) echo 550.54.14  ;;
    12.5) echo 555.42.02  ;;
    12.6) echo 560.28.03  ;;
    12.7) echo 565.57.01  ;;
    12.8) echo 570.26.00  ;;
    12.9) echo 575.51.03  ;;
    13.0) echo 580.65.06  ;;
    *)    echo "" ;;
  esac
}

ver_ge() {  # $1 >= $2 ?
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]
}

check_driver_cuda_compat() {
  local MIN
  MIN=$(cuda_min_driver "${CUDA_VER%.*}")
  if [ -z "$MIN" ]; then
    warn "CUDA ${CUDA_VER} 不在校验表内,请自行确认驱动 ${DRIVER_VER} 满足最低要求"
    return
  fi
  if ver_ge "$DRIVER_VER" "$MIN"; then
    info "版本对齐: 驱动 ${DRIVER_VER} ≥ CUDA ${CUDA_VER} 最低要求 ${MIN}"
  else
    err "驱动 ${DRIVER_VER} < CUDA ${CUDA_VER} 最低要求 ${MIN}
  换驱动: --driver ${MIN} 或更高
  换 CUDA: --cuda <更低版本>(参考 docs.nvidia.com/cuda/cuda-toolkit-release-notes)"
  fi
}

# ================================================================
# 卸载
# ================================================================
uninstall() {
  title "卸载 NVIDIA 驱动 + CUDA(二进制方式)"
  warn "黑屏无法进系统时: GRUB → Recovery mode → root shell 执行本脚本 --uninstall"
  echo ""

  if [ -x /usr/local/cuda*/bin/cuda-uninstaller ] 2>/dev/null; then
    info "运行 cuda-uninstaller..."
    /usr/local/cuda*/bin/cuda-uninstaller --silent 2>/dev/null || true
  fi
  if [ -x /usr/bin/nvidia-uninstall ]; then
    info "运行 nvidia-uninstall..."
    /usr/bin/nvidia-uninstall --silent 2>/dev/null || true
  fi

  # dkms 残留
  if command -v dkms &>/dev/null; then
    dkms status 2>/dev/null | grep -i nvidia | cut -d: -f1 | cut -d/ -f1,2 | sort -u | \
      while read -r MOD; do dkms remove "$MOD" --all 2>/dev/null || true; done
  fi

  rm -f /etc/modprobe.d/blacklist-nouveau.conf \
        /etc/modprobe.d/nvidia*.conf \
        /etc/modules-load.d/nvidia*.conf \
        /etc/profile.d/cuda.sh \
        /etc/apt/sources.list.d/nvidia-container-toolkit.list \
        /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  apt-get autoremove -y -qq 2>/dev/null || true
  update-initramfs -u >/dev/null 2>&1 || true
  info "已卸载,重启生效: reboot"
  exit 0
}

# ================================================================
# 环境准备
# ================================================================
prepare_env() {
  title "环境准备"
  apt-get update -qq
  apt-get install -y -qq pciutils build-essential dkms "linux-headers-$(uname -r)" >/dev/null
  info "编译依赖已就绪(gcc / dkms / linux-headers-$(uname -r))"

  # nouveau blacklist(已加载才需要处理)
  if lsmod | grep -q '^nouveau'; then
    if [ ! -f /etc/modprobe.d/blacklist-nouveau.conf ]; then
      cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
      update-initramfs -u >/dev/null 2>&1
      warn "nouveau 已 blacklist,重启后 nouveau 才真正卸载(重启后重跑本脚本)"
      NEED_REBOOT=true
    else
      warn "nouveau 仍在加载但 blacklist 已存在,重启后生效"
      NEED_REBOOT=true
    fi
  else
    info "nouveau 未加载"
  fi

  # 图形会话会占用驱动,先停(无图形界面则跳过)
  for DM in gdm3 lightdm sddm; do
    if systemctl is-active "$DM" &>/dev/null; then
      warn "停止 ${DM}(驱动安装期间不能有 X 会话)..."
      systemctl stop "$DM"
      STOPPED_DM="${DM}"
    fi
  done
}

# ================================================================
# 下载
# ================================================================
fetch() {  # fetch <url> <dest-file>
  local URL="$1" DEST="$2"
  info "下载 $(basename "$DEST")..."
  curl -fSL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$DEST" "$URL" \
    || err "下载失败: ${URL}
  国内拉不动时: 能联网机器 wget 后 scp 到 chfs,再用 --local-* 指定本地文件"
  [ -s "$DEST" ] || err "下载的文件为空: ${DEST}"
}

# ================================================================
# 驱动(.run)
# ================================================================
install_driver() {
  title "安装 NVIDIA 驱动 ${DRIVER_VER}($([ "$KERNEL_OPEN" = true ] && echo "开源 kernel-open" || echo "闭源 proprietary"))"

  if command -v nvidia-smi &>/dev/null; then
    local CUR
    CUR=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
    if [ "$CUR" = "$DRIVER_VER" ]; then
      info "驱动 ${DRIVER_VER} 已安装,跳过"
      return
    fi
    [ -n "$CUR" ] && warn "当前驱动 ${CUR} → 将装 ${DRIVER_VER}"
  fi

  local RUN_FILE="/tmp/NVIDIA-Linux-x86_64-${DRIVER_VER}.run"
  if [ -n "$LOCAL_DRIVER" ]; then
    [ -f "$LOCAL_DRIVER" ] || err "本地驱动文件不存在: ${LOCAL_DRIVER}"
    RUN_FILE="$LOCAL_DRIVER"
    info "使用本地驱动: ${RUN_FILE}"
  else
    fetch "${NVIDIA_DL_BASE}/${DRIVER_VER}/NVIDIA-Linux-x86_64-${DRIVER_VER}.run" "$RUN_FILE"
  fi

  chmod +x "$RUN_FILE"
  local OPEN_FLAG=""
  [ "$KERNEL_OPEN" = true ] && OPEN_FLAG="-m=kernel-open"
  info "安装驱动(--silent --dkms ${OPEN_FLAG})..."
  bash "$RUN_FILE" --silent --dkms --no-questions $OPEN_FLAG </dev/null \
    || err "驱动安装失败,查 /var/log/nvidia-installer.log"

  rm -f "/tmp/NVIDIA-Linux-x86_64-${DRIVER_VER}.run" 2>/dev/null || true
  # 不在 --local 时才 rm(LOCAL 模式不删用户文件)
  [ -n "$LOCAL_DRIVER" ] || rm -f "$RUN_FILE"

  modprobe nvidia 2>/dev/null && info "nvidia 模块已加载" || warn "模块未能立即加载,重启后生效(NEED_REBOOT=true)"
  # 开源模块用 nvidia_drm modeset,写入 modules-load 保证开机自动加载
  cat > /etc/modules-load.d/nvidia.conf << 'EOF'
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF
}

# ================================================================
# CUDA(.run, 只装 toolkit 不装驱动)
# ================================================================
install_cuda() {
  title "安装 CUDA ${CUDA_VER}(.run toolkit,不含驱动)"

  if [ -x "/usr/local/cuda-${CUDA_VER%.*}/bin/nvcc" ]; then
    info "CUDA ${CUDA_VER%.*} 已安装(/usr/local/cuda-${CUDA_VER%.*}),跳过"
    write_cuda_env
    return
  fi

  local RUN_FILE="/tmp/cuda_${CUDA_VER}_linux.run"
  if [ -n "$LOCAL_CUDA" ]; then
    [ -f "$LOCAL_CUDA" ] || err "本地 CUDA 文件不存在: ${LOCAL_CUDA}"
    RUN_FILE="$LOCAL_CUDA"
    info "使用本地 CUDA: ${RUN_FILE}"
  else
    fetch "${CUDA_DL_BASE}/${CUDA_VER}/local_installers/cuda_${CUDA_VER}_linux.run" "$RUN_FILE"
  fi

  chmod +x "$RUN_FILE"
  info "安装 CUDA toolkit --silent --toolkit --no-opengl-libs(不带驱动,不覆盖 libGL)..."
  bash "$RUN_FILE" --silent --toolkit --no-opengl-libs </dev/null \
    || err "CUDA 安装失败,查 /var/log/cuda-installer.log"

  [ -n "$LOCAL_CUDA" ] || rm -f "$RUN_FILE"
  [ -x "/usr/local/cuda-${CUDA_VER%.*}/bin/nvcc" ] || err "nvcc 未找到,CUDA 安装异常"

  write_cuda_env
  info "CUDA 安装完成: /usr/local/cuda-${CUDA_VER%.*}"
}

write_cuda_env() {
  cat > /etc/profile.d/cuda.sh << 'EOF'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
EOF
  info "已写 /etc/profile.d/cuda.sh(PATH + LD_LIBRARY_PATH,新 shell 生效)"
}

# ================================================================
# nvidia-container-toolkit(Nexus apt,官方无 .run)
# ================================================================
install_toolkit() {
  title "安装 nvidia-container-toolkit(Nexus apt)"
  local KEYRING="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
  local LIST_FILE="/etc/apt/sources.list.d/nvidia-container-toolkit.list"

  if command -v nvidia-ctk &>/dev/null; then
    info "nvidia-container-toolkit 已安装,跳过"
  else
    curl -fsSL "${NEXUS}/libnvidia-container/gpgkey" \
      | gpg --dearmor --yes -o "${KEYRING}"
    curl -fsSL "${NEXUS}/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
      | sed -e "s#https://nvidia.github.io/libnvidia-container/#${NEXUS}/libnvidia-container/#g" \
            -e "s#^deb #deb [signed-by=${KEYRING}] #" \
      > "${LIST_FILE}"
    apt-get update -qq
    apt-get install -y nvidia-container-toolkit
    info "toolkit 已安装"
  fi

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
STOPPED_DM=""

[ "$DO_UNINSTALL" = true ] && uninstall

[ -n "$DRIVER_VER" ] || DRIVER_VER="$DEFAULT_DRIVER_VER"
[ -n "$CUDA_VER" ]   || CUDA_VER="$DEFAULT_CUDA_VER"

# 开源模块最低要求:Turing(Arch >= 7.0, GTX 16xx / RTX 20xx 起)
if [ "$KERNEL_OPEN" = true ]; then
  GPU_MODEL=$(lspci 2>/dev/null | grep -i nvidia | head -1 || true)
  if echo "$GPU_MODEL" | grep -qiE 'gtx 9[0-9]0|gtx 10[0-9]0|pascal|kepler|maxwell'; then
    err "检测到 Pascal 及更老架构,GPU 不支持开源内核模块,去掉 --kernel-open 用闭源"
  fi
  info "kernel-open 模式(Turing+ 架构适用)"
fi

# 版本对齐校验(装 CUDA 时才需要;driver-only 跳过)
if [ "$ONLY_DRIVER" != true ]; then
  check_driver_cuda_compat
fi

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

# 恢复被停掉的图形会话
if [ -n "$STOPPED_DM" ]; then
  info "恢复 ${STOPPED_DM}..."
  systemctl start "$STOPPED_DM" 2>/dev/null || true
fi

# ================================================================
# 验证
# ================================================================
title "完成"
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  info "驱动: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)"
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
else
  warn "nvidia-smi 不可用,重启后生效: reboot"
  NEED_REBOOT=true
fi
if [ -x /usr/local/cuda/bin/nvcc ]; then
  info "CUDA: $(/usr/local/cuda/bin/nvcc --version | tail -1 | grep -oP 'release \K[0-9.]+')"
fi
echo ""
echo "验证命令:"
echo "  nvidia-smi"
echo "  /usr/local/cuda/bin/nvcc --version"
echo "  docker run --rm --gpus all ubuntu:22.04 nvidia-smi   # 需要 toolkit + runtime 已配"
echo ""
echo "卸载:"
echo "  sudo bash $0 --uninstall"
[ "$NEED_REBOOT" = true ] && echo "" && warn "存在待重启项(reboot 后重跑本脚本可验证)"
exit 0
