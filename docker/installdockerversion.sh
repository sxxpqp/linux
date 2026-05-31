#!/bin/bash
# installdocker.sh - 自动检测架构的Docker 20.10二进制安装脚本
# 使用方法: ./installdocker.sh 20.10

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 无颜色

# 检查参数
if [ $# -ne 1 ]; then
    echo -e "${RED}错误:${NC} 请指定 Docker 版本，例如: ./installdocker.sh 20.10"
    exit 1
fi
VERSION=$1


# 确保以root或sudo权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误:${NC} 请使用root权限或sudo运行此脚本"
    exit 1
fi

# 打印欢迎信息
echo -e "${GREEN}===== 开始安装 Docker ${VERSION} 二进制版本 ====${NC}"
echo -e "${YELLOW}注意:${NC} 此脚本将根据系统架构自动选择合适的安装包"
echo -e "${YELLOW}注意:${NC} 安装过程需要联网下载 Docker 二进制文件"
echo ""

# 检测系统架构
ARCH=$(uname -m)
case $ARCH in
    x86_64|amd64)
        ARCH_DIR="x86_64"
        ARCH_NAME="x86_64"
        ;;
    aarch64|arm64)
        ARCH_DIR="arm64"
        ARCH_NAME="ARM64"
        ;;
    armv7l|armhf)
        ARCH_DIR="armhf"
        ARCH_NAME="ARM HF"
        ;;
    *)
        echo -e "${RED}错误:${NC} 不支持的架构: $ARCH"
        echo "支持的架构: x86_64, ARM64, ARM HF"
        exit 1
        ;;
esac

echo -e "${YELLOW}信息:${NC} 检测到系统架构: $ARCH_NAME ($ARCH)"

# 下载Docker二进制文件
DOWNLOAD_DIR="/tmp/docker-download"
DOCKER_TARBALL="docker-${VERSION}.tgz"
DOCKER_URL="https://mirrors.aliyun.com/docker-ce/linux/static/stable/${ARCH_DIR}/${DOCKER_TARBALL}"

mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"
echo $DOCKER_URL
echo -e "${YELLOW}信息:${NC} 正在下载 Docker ${VERSION} for ${ARCH_NAME} 二进制文件..."

# 修复后的下载逻辑（添加正确的缩进和条件判断）
if [ ! -f "$DOCKER_TARBALL" ]; then
    wget "$DOCKER_URL"
fi

if [ ! -f "$DOCKER_TARBALL" ]; then
    echo -e "${RED}错误:${NC} 下载 Docker 二进制文件失败，请检查网络连接"
    exit 1
fi

echo -e "${GREEN}成功:${NC} Docker 二进制文件下载完成"

# 安装Docker二进制文件
echo -e "${YELLOW}信息:${NC} 正在安装 Docker 二进制文件..."
tar -xzf "$DOCKER_TARBALL"
chmod +x docker/*

# 复制到系统路径
cp docker/* /usr/bin/

# 清理临时文件
rm -rf "$DOWNLOAD_DIR"

echo -e "${GREEN}成功:${NC} Docker 二进制文件安装完成"

# 配置Docker运行环境
echo -e "${YELLOW}信息:${NC} 正在配置 Docker 运行环境..."

# 创建必要的目录
mkdir -p /var/lib/docker
mkdir -p /etc/docker

# 创建systemd服务文件
cat > /etc/systemd/system/docker.service << EOF
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target nss-lookup.target docker.socket firewalld.service containerd.service time-set.target
Wants=network-online.target containerd.service
Requires=docker.socket
StartLimitBurst=3
StartLimitIntervalSec=60

[Service]
Type=notify
# the default is not to use systemd for cgroups because the delegate issues still
# exists and systemd currently does not support the cgroup feature set required
# for containers run by docker
ExecStart=/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
RestartSec=2
Restart=always

# Having non-zero Limit*s causes performance problems due to accounting overhead
# in the kernel. We recommend using cgroups to do container-local accounting.
LimitNPROC=infinity
LimitCORE=infinity

# Comment TasksMax if your systemd version does not support it.
# Only systemd 226 and above support this option.
TasksMax=infinity

# set delegate yes so that systemd does not reset the cgroups of docker containers
Delegate=yes

# kill only the docker process, not all processes in the cgroup
KillMode=process
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/docker.socket << EOF
[Unit]
Description=Docker Socket for the API

[Socket]
# If /var/run is not implemented as a symlink to /run, you may need to
# specify ListenStream=/var/run/docker.sock instead.
ListenStream=/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF
cat > /usr/lib/systemd/system/containerd.service << 'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

# 启动Docker服务
echo -e "${YELLOW}信息:${NC} 正在启动 Docker 服务..."
systemctl daemon-reload
systemctl enable containerd
systemctl start containerd
systemctl enable docker.socket
systemctl start docker.socket
systemctl enable docker
systemctl start docker

# 验证Docker安装
echo -e "${YELLOW}信息:${NC} 正在验证 Docker 安装..."
if docker version > /dev/null 2>&1; then
    echo -e "${GREEN}成功:${NC} Docker ${VERSION} for ${ARCH_NAME} 安装完成!"
    echo "Docker 版本信息:"
    docker version
else
    echo -e "${RED}错误:${NC} Docker 启动失败，请检查日志:"
    systemctl status docker
    exit 1
fi

# 配置非root用户使用Docker
echo -e "${YELLOW}信息:${NC} 正在配置非root用户使用Docker..."
groupadd -r docker 2>/dev/null || true
usermod -aG docker "$(who am i | awk '{print $1}')"

echo ""
echo -e "${GREEN}===== Docker ${VERSION} for ${ARCH_NAME} 二进制安装完成 ====${NC}"
echo -e "${YELLOW}提示:${NC} 如需使用Docker命令，非root用户需要重新登录或执行 'newgrp docker'"
echo -e "${YELLOW}提示:${NC} 可以使用 'docker run hello-world' 测试Docker是否正常工作"