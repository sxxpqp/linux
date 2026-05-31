#!/bin/bash
# uninstall_docker.sh - Docker 20.10 二进制安装版本卸载脚本
# 使用方法: ./uninstall_docker.sh

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

# 确保以root或sudo权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误:${NC} 请使用root权限或sudo运行此脚本"
    exit 1
fi

# 打印欢迎信息
clear
echo -e "${RED}===== Docker 卸载工具 ====${NC}"
echo -e "${YELLOW}警告:${NC} 此操作将卸载 Docker 20.10 二进制安装版本!"
echo "以下内容将被删除:"
echo "  - /usr/bin/docker* 二进制文件"
echo "  - /etc/systemd/system/docker.service 服务配置"
echo "  - Docker 系统服务"
echo ""
echo "以下内容将被保留:"
echo "  - /var/lib/docker/ 数据目录 (如需删除请手动操作)"
echo "  - /etc/docker/ 配置目录"
echo ""

# 确认卸载
read -p "确认卸载 Docker  (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
    echo -e "${YELLOW}信息:${NC} 已取消卸载操作"
    exit 0
fi

# 检测Docker是否安装
if [ ! -f "/usr/bin/docker" ]; then
    echo -e "${YELLOW}信息:${NC} 未检测到 Docker  二进制安装版本"
    exit 0
fi

# 停止Docker服务
echo -e "${YELLOW}信息:${NC} 正在停止 Docker 服务..."
systemctl stop docker 2>/dev/null
systemctl disable docker 2>/dev/null

# 卸载Docker二进制文件
echo -e "${YELLOW}信息:${NC} 正在删除 Docker 二进制文件..."
rm -f /usr/bin/docker*
rm -f /usr/bin/docker-containerd
rm -f /usr/bin/docker-runc
rm -f /usr/bin/containerd*
rm -f /usr/bin/ctr
rm -f /usr/bin/runc


# 移除服务配置
echo -e "${YELLOW}信息:${NC} 正在删除 Docker 服务配置..."
rm -f /etc/systemd/system/docker.service

# 重新加载systemd配置
echo -e "${YELLOW}信息:${NC} 正在重新加载系统服务配置..."
systemctl daemon-reload 2>/dev/null

# 清理残留
echo -e "${YELLOW}信息:${NC} 正在清理残留数据..."
groupdel docker 2>/dev/null

# 验证卸载结果
if [ ! -f "/usr/bin/docker" ]; then
    echo -e "${GREEN}成功:${NC} Docker 20.10 二进制安装版本已成功卸载!"
    echo "如需完全清理数据，请手动删除 /var/lib/docker 目录"
else
    echo -e "${RED}错误:${NC} Docker 卸载失败，请检查以下文件是否删除:"
    echo "  /usr/bin/docker"
    echo "  /usr/bin/docker-containerd"
    echo "  /usr/bin/docker-runc"
    echo "  /etc/systemd/system/docker.service"
    exit 1
fi

echo ""
echo -e "${GREEN}===== 卸载完成 ====${NC}"