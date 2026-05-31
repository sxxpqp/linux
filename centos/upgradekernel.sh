#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/centos/upgradekernel.sh
set -euo pipefail
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
if [[ $EUID -ne 0 ]]; then
  log_error "请以 root 身份执行本脚本"
  exit 1
fi
log_info "=== CentOS 7 内核升级 · 节点：$(hostname) ==="
log_info "当前内核：$(uname -r)"

log_info "[1/2] 下载 kernel-ml 5.15.63 RPM 包 ..."
MIRROR="https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/"
VER="5.15.63-1.el7.x86_64"
WORK_DIR="/tmp/kernel-ml-rpms"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# 下载 RPM 包
curl -sL "${MIRROR}/kernel-ml-${VER}.rpm" -o "kernel-ml-${VER}.rpm"
curl -sL "${MIRROR}/kernel-ml-devel-${VER}.rpm" -o "kernel-ml-devel-${VER}.rpm"
curl -sL "${MIRROR}/kernel-ml-headers-${VER}.rpm" -o "kernel-ml-headers-${VER}.rpm"
curl -sL "${MIRROR}/kernel-ml-tools-${VER}.rpm" -o "kernel-ml-tools-${VER}.rpm"
curl -sL "${MIRROR}/kernel-ml-tools-libs-${VER}.rpm" -o "kernel-ml-tools-libs-${VER}.rpm"
curl -sL "${MIRROR}/kernel-ml-tools-libs-devel-${VER}.rpm" -o "kernel-ml-tools-libs-devel-${VER}.rpm"

log_info "安装 kernel-ml RPM (自动跳过冲突包) ..."
yum localinstall -y kernel-ml-* --skip-broken
if rpm -qa | grep -q "kernel-ml-5.15"; then
  log_info "kernel-ml 5.15.63 安装成功 ✓"
else
  log_error "kernel-ml 安装失败，请检查 RPM 包或网络"
  exit 1
fi

log_info "[2/2] 设置默认启动内核 ..."
yum install -y grub2-pc
sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  全部完成！请重启节点使新内核生效                        ║${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}║  reboot                                                   ║${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}║  重启后验证：                                             ║${NC}"
echo -e "${GREEN}║  uname -r           # 应显示 5.15.63-1.el7.x86_64       ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
log_warn "⚠️  逐台 Worker 重启，避免同时操作导致集群不可用"
