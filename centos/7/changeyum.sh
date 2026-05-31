#!/bin/bash

# CentOS 7 源更新脚本 - 优化版
# 功能：备份原YUM源，替换为新源并更新缓存

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查命令是否存在
check_command() {
    if ! command -v $1 &> /dev/null; then
        log_error "$1 命令不存在，请先安装"
        exit 1
    fi
}

# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本需要root权限执行，请使用sudo或切换到root用户"
        exit 1
    fi
}

# 主函数
main() {
    log_info "开始CentOS 7源更新流程"
    
    # 检查必要命令
    check_command curl
    check_command yum
    
    # 确认用户操作
    read -p "此操作将替换系统YUM源，是否继续? (y/n): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "用户取消操作，脚本退出"
        exit 0
    fi
    
    # 备份原YUM源目录
    log_info "备份原YUM源配置"
    backup_dir="/etc/yum.repos.dback_$(date +%Y%m%d%H%M%S)"
    if [ -d "/etc/yum.repos.d" ]; then
        if mv /etc/yum.repos.d "$backup_dir"; then
            log_info "原YUM源已备份到 $backup_dir"
        else
            log_error "备份原YUM源失败，请检查权限"
            exit 1
        fi
    else
        log_warn "原YUM源目录不存在，跳过备份"
    fi
    
    # 创建新YUM源目录
    log_info "创建新YUM源目录"
    if mkdir -p /etc/yum.repos.d; then
        log_info "新YUM源目录创建成功"
    else
        log_error "创建新YUM源目录失败，请检查权限"
        exit 1
    fi
    
    # 下载新YUM源配置
    log_info "下载新YUM源配置文件"
    repo_url="https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/CentOS-Base.repo"
    repo_file="/etc/yum.repos.d/CentOS-Base.repo"
    
    if curl -L -o "$repo_file" "$repo_url"; then
        if [ -f "$repo_file" ]; then
            log_info "YUM源配置文件下载成功"
        else
            log_error "YUM源配置文件下载失败，文件不存在"
            exit 1
        fi
    else
        log_error "YUM源配置文件下载失败，请检查网络连接"
        exit 1
    fi
    
    # 清理YUM缓存
    log_info "清理YUM缓存"
    if yum clean all; then
        log_info "YUM缓存清理成功"
    else
        log_error "YUM缓存清理失败"
    fi
    
    # 生成YUM缓存
    log_info "生成YUM缓存"
    if yum makecache; then
        log_info "YUM缓存生成成功"
    else
        log_error "YUM缓存生成失败，请检查源配置"
        exit 1
    fi
    
    # 显示仓库列表
    log_info "显示可用软件仓库"
    yum repolist
    
    log_info "CentOS 7源更新完成!"
}

# 执行主函数
main