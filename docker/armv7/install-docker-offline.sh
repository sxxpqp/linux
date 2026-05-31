#!/bin/bash

DOCKER_DIR="/opt" # 本地 Docker 离线包目录路径
DOCKER_VERSION="27.3.1" # 默认 Docker 版本
DOCKER_File="docker-$DOCKER_VERSION.tgz"
INSTALL_DIR="/usr/local/bin" # Docker 安装目录
DOCKER_ROOT="/var/lib/docker" # Docker 数据目录
#DOWNLOAD_URL="https://minio.sxxpqp.top/docker" # 下载 URL
DOWNLOAD_URL="https://chfs.sxxpqp.top:8443/chfs/shared/docker/armv7" # 下载 URL
function download_file() {
    # 下载文件函数
    local file_url="$1"
    local file_path="$2"

    if [ ! -f "$file_path" ]; then
        echo "Downloading $file_url ..."
        curl -o "$file_path" "$file_url"
        if [ $? -ne 0 ]; then
            echo "Failed to download $file_url"
            exit 1
        fi
    else
        echo "$file_path already exists, skipping download."
    fi
}

function list_versions() {
    # 列出可用的 Docker 版本
    echo "Available Docker versions:"
    ls "$DOCKER_DIR"
}

function choose_version() {
    # 用户选择 Docker 版本
    list_versions
    read -p "Enter the Docker version you want to install (default: $DOCKER_VERSION): " user_version
    if [ -n "$user_version" ]; then
        DOCKER_VERSION="$user_version"
        DOCKER_File="docker-$DOCKER_VERSION.tgz"
    fi
    if [ ! -f "$DOCKER_DIR/$DOCKER_File" ]; then
        echo "Version file not found in the local directory. Attempting to download..."
        download_file "$DOWNLOAD_URL/$DOCKER_File" "$DOCKER_DIR/$DOCKER_File"
    fi
}

function install_docker() {
    # 检测是否已安装 Docker
    if command -v dockerd >/dev/null 2>&1; then
        echo "Docker is already installed. Skipping installation."
        return
    fi

    # 解压 Docker 包并安装
    echo "Installing Docker version $DOCKER_VERSION..."
    tar -xzf "$DOCKER_DIR/$DOCKER_File" -C /tmp/
    cp /tmp/docker/* "$INSTALL_DIR/"

    # 配置 Docker 服务文件
    echo "[*] Register Docker service..."
    cat > /etc/systemd/system/docker.service << EOF
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd
ExecReload=/bin/kill -s HUP \$MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF

    # 赋予 systemd 文件可执行权限
    chmod a+x /etc/systemd/system/docker.service
    chmod a+x /usr/local/bin/dockerd

    # 创建并配置 Docker 配置文件
    echo "[*] Create Docker config and modify it..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << EOF
{
    "log-opts": {},
    "registry-mirrors": [
        "https://dockerproxy.1panel.live",
        "https://dockerhubk.sxxpqp.top"
    ]
}
EOF

    # 重载 systemd 配置并启动 Docker 服务
    systemctl daemon-reload
    systemctl enable docker
    systemctl start docker

    if [ $? -eq 0 ]; then
        echo "Docker $DOCKER_VERSION installed and service started successfully."
    else
        echo "Docker installed, but service start failed."
    fi
    install_docker_compose
}

function install_docker_compose() {
    # 检查 Docker Compose 是否已安装
    local compose_file="$DOCKER_DIR/docker-compose-linux-armv7"
    download_file "$DOWNLOAD_URL/docker-compose-linux-armv7" "$compose_file"

    if [ -f ~/.docker/cli-plugins/docker-compose ]; then
        echo "Docker Compose is already installed. Skipping installation."
        return
    fi

    # 安装 Docker Compose 插件
    echo "Installing Docker Compose..."
    mkdir -p ~/.docker/cli-plugins/
    cp "$compose_file" ~/.docker/cli-plugins/docker-compose
    chmod +x ~/.docker/cli-plugins/docker-compose

    # 验证安装是否成功
    if [ $? -eq 0 ]; then
        echo "Docker Compose installed successfully."
    else
        echo "Failed to install Docker Compose."
    fi
}

function uninstall_docker() {
    # 卸载 Docker
    echo "Uninstalling Docker..."
    rm -f "$INSTALL_DIR/docker"*

    # 停止并禁用 Docker 服务
    systemctl stop docker
    systemctl disable docker
    rm -f /etc/systemd/system/docker.service
    systemctl daemon-reload

    # 删除 Docker 配置文件
    rm -rf /etc/docker

    # 卸载 Docker Compose
    echo "Uninstalling Docker Compose..."
    rm -f ~/.docker/cli-plugins/docker-compose

    echo "Docker and Docker Compose uninstalled successfully."
}

function main_menu() {
    # 主菜单，用户可以使用上下键选择
    while true; do
        echo "Choose an action:"
        echo "1) Install Docker"
        echo "2) Install Docker Compose"
        echo "3) Uninstall Docker"
        echo "4) List available versions"
        echo "5) Exit"
        read -n 1 -p "Select an option [1-5]: " choice
        echo
        case $choice in
            1)
                choose_version
                install_docker
                ;;
            2)
                install_docker_compose
                ;;
            3)
                uninstall_docker
                ;;
            4)
                list_versions
                ;;
            5)
                exit 0
                ;;
            *)
                echo "Invalid option. Please select again."
                ;;
        esac
    done
}

# 运行主菜单
main_menu
