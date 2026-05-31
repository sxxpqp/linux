#!/bin/bash

# 自适应系统的Docker卸载脚本
# 支持Debian/Ubuntu（apt）和CentOS/RHEL（yum）系统

# 检测系统类型
OS_TYPE=$(uname -s)
PACKAGE_MANAGER=""
DOCKER_PACKAGES=""

# 根据系统类型设置包管理器和Docker组件列表
if [ "$OS_TYPE" == "Linux" ]; then
    # 检测具体发行版
    if [ -f /etc/debian_version ]; then
        # Debian/Ubuntu系统
        PACKAGE_MANAGER="apt-get"
        DOCKER_PACKAGES="docker.io docker-doc docker-compose podman-docker containerd runc"
    elif [ -f /etc/redhat-release ]; then
        # CentOS/RHEL系统
        PACKAGE_MANAGER="yum"
        DOCKER_PACKAGES="docker docker-client docker-common docker-engine docker-compose podman-docker containerd.io runc"
    else
        echo "不支持的Linux发行版，无法确定包管理器。"
        exit 1
    fi
else
    echo "仅支持Linux系统，当前系统：$OS_TYPE"
    exit 1
fi

# 输出当前系统和卸载计划
echo "检测到系统：$OS_TYPE"
echo "使用包管理器：$PACKAGE_MANAGER"
echo "即将卸载的Docker组件：$DOCKER_PACKAGES"

# # 交互式确认（可选）
# read -p "是否继续卸载？(y/n): " CONFIRM
# if [ "$CONFIRM" != "y" ]; then
#     echo "已取消卸载操作。"
#     exit 0
# fi

# 执行卸载
echo "开始卸载Docker组件..."
for pkg in $DOCKER_PACKAGES; do
    echo "正在卸载 $pkg..."
    
    # 根据包管理器执行卸载命令
    if [ "$PACKAGE_MANAGER" == "apt-get" ]; then
        $PACKAGE_MANAGER remove $pkg -y
    else
        $PACKAGE_MANAGER remove $pkg -y
    fi
    
    # 检查卸载结果
    if [ $? -eq 0 ]; then
        echo "$pkg 卸载成功"
    else
        echo "$pkg 未安装或卸载失败，跳过"
    fi
done

# 清理残留（Debian/Ubuntu）
if [ "$PACKAGE_MANAGER" == "apt-get" ]; then
    echo "清理残留依赖..."
    apt-get autoremove -y
    apt-get clean
fi

# 清理残留（CentOS/RHEL）
if [ "$PACKAGE_MANAGER" == "yum" ]; then
    echo "清理残留依赖..."
    yum autoremove -y
    yum clean all
fi

echo "Docker组件卸载完成！"