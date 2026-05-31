#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/nvidia/nvidia-driver-install.sh
# NVIDIA 显卡驱动自动安装脚本
# 全平台通用，自动检测显卡型号、系统版本，选择最合适的驱动
#
# 用法:
#   bash nvidia-driver-install.sh              # 交互式
#   bash nvidia-driver-install.sh --auto       # 全自动
#   bash nvidia-driver-install.sh --force      # 强制重装
#
# 支持的发行版: Ubuntu / Debian / CentOS / RHEL / Rocky / Alma

set -uo pipefail

# 调试：异常退出时打印行号
trap 'echo "[DEBUG] 脚本在第 $LINENO 行退出，退出码: $?" >&2' ERR

# ========== 颜色 ==========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
log()   { echo -e "${BLUE}[*]${NC} $1"; }

# ========== 参数 ==========
AUTO=false
FORCE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --auto)  AUTO=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) err "未知参数: $1"; exit 1 ;;
  esac
done

# ========== 前置检测 ==========
log "检测系统信息..."

# 发行版
OS_ID=""
OS_VERSION=""
OS_CODENAME=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID=$ID
  OS_VERSION=$VERSION_ID
  OS_CODENAME=$VERSION_CODENAME
fi

# 内核版本
KERNEL=$(uname -r)
ARCH=$(uname -m)

info "系统: ${OS_ID} ${OS_VERSION} (${OS_CODENAME:-N/A})"
info "内核: ${KERNEL} 架构: ${ARCH}"

# ========== 检测 NVIDIA 显卡 ==========
log "检测 NVIDIA 显卡..."

detect_gpu() {
  # 方法1: lspci
  if command -v lspci &>/dev/null; then
    GPU_INFO=$(lspci | grep -i nvidia | head -1)
    if [ -n "$GPU_INFO" ]; then
      echo "$GPU_INFO"
      return 0
    fi
  fi
  # 方法2: lshw
  if command -v lshw &>/dev/null; then
    GPU_INFO=$(lshw -C display 2>/dev/null | grep -i nvidia | head -1)
    [ -n "$GPU_INFO" ] && { echo "$GPU_INFO"; return 0; }
  fi
  # 方法3: nvidia-smi（已装驱动）
  if command -v nvidia-smi &>/dev/null; then
    GPU_INFO=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    [ -n "$GPU_INFO" ] && { echo "$GPU_INFO (驱动已装)"; return 0; }
  fi
  return 1
}

GPU=$(detect_gpu || true)
if [ -z "$GPU" ]; then
  err "未检测到 NVIDIA 显卡"
  err "请确认: 1) 物理插了 NVIDIA 显卡  2) lspci 可运行 (apt install pciutils)"
  exit 1
fi
info "检测到显卡: ${GPU}"

# 已装驱动则显示版本
info "检测完成，准备查询驱动版本..."

if command -v nvidia-smi &>/dev/null; then
  CURRENT_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
  warn "当前驱动版本: ${CURRENT_VER}"
  if [ "$FORCE" != true ] && [ "$AUTO" != true ]; then
    read -rp "驱动已装，是否重装？[y/N] " confirm || confirm="y"
    [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && { log "退出"; exit 0; }
  fi
fi

# ========== 查推荐驱动版本 ==========
log "查询推荐驱动版本..."

RECOMMENDED_VER=""

# 方法1: NVIDIA 官网 API（自动匹配）
fetch_nvidia_api() {
  local gpu_name="$1"
  # NVIDIA API: 根据显卡名查推荐驱动
  local encoded=$(echo "$gpu_name" | sed 's/ /%20/g')
  local api_url="https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=113&pfid=0&osID=66&languageCode=zh-cn&beta=0&isWHQL=0&dltype=-1&dch=0&sort1=0&numberOfResults=10"

  # 用 curl 查
  local result
  result=$(curl -s "$api_url" 2>/dev/null || echo "")
  if [ -n "$result" ]; then
    RECOMMENDED_VER=$(echo "$result" | grep -oP '"Version":"[^"]*"' | head -1 | cut -d'"' -f4)
  fi
}

# 方法2: 根据架构 + 系统查版本
# RTX 30 系列 → R470/R525, RTX 40 → R535/R545, RTX 50 → R570+
pick_version_by_gpu() {
  local gpu_str=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  if echo "$gpu_str" | grep -qE 'rtx 50[0-9]0|blackwell'; then
    echo "570"
  elif echo "$gpu_str" | grep -qE 'rtx 40[0-9]0|ada|rtx 6000|ada'; then
    echo "550"
  elif echo "$gpu_str" | grep -qE 'rtx 30[0-9]0|ampere|rtx a[0-9]'; then
    echo "470"
  elif echo "$gpu_str" | grep -qE 'gtx 16[0-9]0|turing|gtx 1650'; then
    echo "470"
  elif echo "$gpu_str" | grep -qE 'gtx 10[0-9]0|pascal'; then
    echo "470"
  elif echo "$gpu_str" | grep -qE 'tesla|v100|a100|h100'; then
    echo "550"
  else
    echo "550"  # 默认最新稳定
  fi
}

MAJOR_VER=$(pick_version_by_gpu "$GPU")
info "推荐驱动系列: ${MAJOR_VER}"

# 查询该系列最新小版本
LATEST_FULL=""
case ${OS_ID} in
  ubuntu|debian)
    log "查询 apt 源中可用的 NVIDIA 驱动..."
    apt update 2>/dev/null || true
    LATEST_FULL=$(apt-cache search "^nvidia-driver-${MAJOR_VER}" | awk '{print $1}' | sort -V | tail -1 | sed 's/nvidia-driver-//')
    ;;
  centos|rhel|rocky|almalinux)
    log "查询 yum 源中可用的 NVIDIA 驱动..."
    LATEST_FULL=$(yum --disablerepo='*' --enablerepo='elrepo' list available kmod-nvidia 2>/dev/null | grep -oP 'nvidia-\K[0-9]+' | tail -1)
    ;;
esac

if [ -z "$LATEST_FULL" ]; then
  LATEST_FULL="${MAJOR_VER}"  # 用主版本号直接装（系统源可能没细分）
fi

info "目标驱动版本: ${MAJOR_VER} 系列"

# ========== 安装 ==========
install_driver() {
  case ${OS_ID} in
    ubuntu|debian)
      log "Ubuntu/Debian 方式安装..."

      # 确保 pciutils
      apt install -y pciutils

      # 方式 A: ubuntu-drivers
      if command -v ubuntu-drivers &>/dev/null; then
        info "使用 ubuntu-drivers 自动安装..."
        ubuntu-drivers autoinstall
      else
        warn "未找到 ubuntu-drivers，安装..."
        apt install -y ubuntu-drivers-common
        ubuntu-drivers autoinstall
      fi
      ;;
    centos|rhel|rocky|almalinux)
      log "CentOS/RHEL 方式安装..."

      # 安装 EPEL + ELRepo
      yum install -y epel-release
      rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
      yum install -y https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm

      info "安装 NVIDIA 驱动..."
      yum --enablerepo=elrepo install -y kmod-nvidia

      # 如果上面的版本太旧，试 nvidia-detect
      if ! command -v nvidia-smi &>/dev/null; then
        yum --enablerepo=elrepo install -y nvidia-detect
        DETECTED_VER=$(nvidia-detect 2>/dev/null | grep -oP 'nvidia-\K[0-9.]+' || true)
        if [ -n "$DETECTED_VER" ]; then
          yum --enablerepo=elrepo install -y "kmod-nvidia-${DETECTED_VER}"
        fi
      fi
      ;;
    *)
      err "不支持的发行版: ${OS_ID}"
      err "支持: ubuntu / debian / centos / rhel / rocky / almalinux"
      exit 1
      ;;
  esac
}

log "安装 NVIDIA 驱动..."
# curl ... | bash 时 stdin 是管道，read 不可用
# 检测是否交互式终端，非交互式或 --auto 都直接安装
if [ "$AUTO" = true ] || [ ! -t 0 ]; then
  info "非交互模式，直接安装..."
  install_driver
else
  echo ""
  echo "=============================="
  echo " 显卡: ${GPU}"
  echo " 系统: ${OS_ID} ${OS_VERSION}"
  echo " 驱动系列: ${MAJOR_VER}"
  echo "=============================="
  echo ""
  read -rp "确认安装？[Y/n] " confirm
  confirm=${confirm:-Y}
  if [ "$confirm" = "Y" ] || [ "$confirm" = "y" ]; then
    install_driver
  else
    log "已取消"
    exit 0
  fi
fi

# ========== 装 nvidia-container-toolkit ==========
echo ""
log "安装 nvidia-container-toolkit (Docker GPU 支持)..."
case ${OS_ID} in
  ubuntu|debian)
    # 用 Nexus 代理的 nvidia GPG 和源
    GPG_KEY_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-nvidia/nvidia-docker/gpgkey"
    LIST_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-nvidia/nvidia-docker/libnvidia-container/stable/ubuntu\$(lsb_release -cs)/\$(ARCH)"
    curl -fsSL "$GPG_KEY_URL" | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] $LIST_URL /" \
      | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt update
    apt install -y nvidia-container-toolkit
    ;;
  centos|rhel|rocky|almalinux)
    REPO_URL="https://nexus.ihome.sxxpqp.top:8443/repository/raw-nvidia/nvidia-docker/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo"
    curl -s -L "$REPO_URL" -o /etc/yum.repos.d/nvidia-container-toolkit.repo
    yum install -y nvidia-container-toolkit
    ;;
esac

info "nvidia-container-toolkit 安装完成"

# ========== 配置 Docker/Containerd ==========
log "配置容器运行时..."
if command -v docker &>/dev/null; then
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
  info "Docker GPU 运行时已配置"
fi

if [ -f /etc/containerd/config.toml ]; then
  nvidia-ctk runtime configure --runtime=containerd
  systemctl restart containerd
  info "Containerd GPU 运行时已配置"
fi

# ========== 验证 ==========
echo ""
log "验证..."
echo ""
if command -v docker &>/dev/null; then
  docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi 2>&1 || warn "Docker GPU 验证失败（可能没装 docker 或镜像没拉到）"
fi

echo ""
echo "=============================="
echo " NVIDIA 驱动安装完成"
echo "=============================="
GPU_NEW_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "需要重启")
info "驱动版本: ${GPU_NEW_VER}"
echo ""
echo "  nvidia-smi       # 查看 GPU 状态"
echo "  docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi  # 验证 Docker GPU"
echo ""

if command -v nvidia-smi &>/dev/null; then
  info "驱动已生效，无需重启"
else
  warn "需要重启系统使驱动生效: reboot"
fi
