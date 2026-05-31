#!/bin/bash
# 系统: Linux (docker-compose)
# Dify — 开源 LLM 应用开发平台 Docker Compose 部署脚本
# 用法: bash <(curl -sL https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/ai/dify/deploy.sh)
#
# 前置要求:
#   - Docker Engine 24+ & Docker Compose v2.24.0+ (docker compose 命令)
#   - CPU ≥ 2 核, 内存 ≥ 4 GiB
#
# 默认安装路径: /opt/dify
# 版本: 支持指定 release tag (如 1.2.0), 默认 latest stable

set -euo pipefail

# ========== 配置 ==========
DIFY_VERSION="${1:-1.14.2}"
INSTALL_DIR="${2:-/opt/dify}"
DIFY_GITHUB="https://github.com/langgenius/dify"

# Nexus 代理前缀（GitHub raw / release / API 走 Nexus）
NEXUS_RAW_GITHUB="https://nexus.ihome.sxxpqp.top:8443/repository/raw-github"
NEXUS_GITHUB_CONTENT="https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent"
NEXUS_API_GITHUB="https://nexus.ihome.sxxpqp.top:8443/repository/raw-github-api"

# ========== 颜色输出 ==========
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# ========== 前置检查 ==========
check_prereqs() {
    if ! command -v docker &>/dev/null; then
        warn "Docker 未安装"
        read -rp "是否自动安装 Docker CE？（Y/n）: " answer
        if [[ "${answer:-Y}" =~ ^[Yy]?$ ]]; then
            info "正在安装 Docker CE..."
            curl -fsSL https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/install.sh | bash -s docker --mirror Aliyun
            systemctl enable --now docker >/dev/null 2>&1
            # 配置 Harbor 镜像加速源
            info "配置 Harbor 镜像加速..."
            mkdir -p /etc/docker
            printf '{\n  "registry-mirrors": ["https://dockerhub.ihome.sxxpqp.top:8443"],\n  "insecure-registries": ["dockerhub.ihome.sxxpqp.top:8443", "ghcr.ihome.sxxpqp.top:8443"],\n  "exec-opts": ["native.cgroupdriver=systemd"],\n  "log-driver": "json-file",\n  "log-opts": {"max-size": "100m", "max-file": "5"}\n}\n' > /etc/docker/daemon.json
            systemctl daemon-reload >/dev/null 2>&1
            systemctl restart docker >/dev/null 2>&1
            # 等待 Docker 就绪（最多等 20 秒）
            for i in $(seq 1 10); do
                if docker info &>/dev/null; then break; fi
                sleep 2
            done
            if ! docker info &>/dev/null; then
                error "Docker 启动失败，请检查: journalctl -u docker"
                exit 1
            fi
            info "Docker 安装完成，镜像加速已配置"
        else
            error "请手动安装 Docker 后重试"
            exit 1
        fi
    fi
    if ! docker compose version &>/dev/null; then
        error "Docker Compose v2 未安装或版本过低。请升级 Docker Engine。"
        exit 1
    fi
    info "Docker: $(docker --version)"
    info "Compose: $(docker compose version)"
    if ! command -v unzip &>/dev/null; then
        info "安装 unzip..." && yum install -y -q unzip 2>/dev/null || apt-get install -y -q unzip 2>/dev/null
    fi
}

# ========== 获取版本 ==========
get_version() {
    if [[ "$DIFY_VERSION" == "latest" ]]; then
        info "通过 GitHub API 获取最新版本..."
        DIFY_VERSION=""
        set +e
        local json
        json=$(curl -fsSL "${NEXUS_API_GITHUB}/repos/langgenius/dify/releases/latest" 2>/dev/null)
        set -e
        if [[ -n "$json" ]]; then
            DIFY_VERSION=$(echo "$json" | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4 | sed 's/^v//')
        fi
        if [[ -z "$DIFY_VERSION" ]]; then
            warn "GitHub API 不可达，使用默认版本 1.14.2"
            DIFY_VERSION="1.14.2"
        fi
    fi
    info "Dify 版本: ${DIFY_VERSION}"
}

# ========== 下载部署文件 ==========
download_dify() {
    local target_dir="${INSTALL_DIR}"
    if [[ -d "$target_dir/docker" ]]; then
        warn "目标目录 ${target_dir} 已存在，跳过下载"
        return
    fi

    info "创建目录: ${target_dir}"
    mkdir -p "$target_dir"

    # 通过 Nexus raw-github 代理下载 Dify release zip
    local zip_url="${NEXUS_RAW_GITHUB}/langgenius/dify/archive/refs/tags/${DIFY_VERSION}.zip"
    local zip_file="/tmp/dify-${DIFY_VERSION}.zip"

    info "下载 Dify v${DIFY_VERSION}..."
    curl -fsSL "$zip_url" -o "$zip_file"

    info "解压到 ${target_dir}..."
    unzip -q "$zip_file" -d "/tmp/dify-extract"
    mv "/tmp/dify-extract/dify-${DIFY_VERSION}/docker" "${target_dir}/docker"
    # 如果有 .env.example 也复制
    if [[ -f "/tmp/dify-extract/dify-${DIFY_VERSION}/docker/.env.example" ]]; then
        cp "/tmp/dify-extract/dify-${DIFY_VERSION}/docker/.env.example" "${target_dir}/docker/.env"
    fi

    # 清理
    rm -f "$zip_file"
    rm -rf "/tmp/dify-extract"

    info "Dify 部署文件已下载到 ${target_dir}/docker"
}

# ========== 配置环境 ==========
setup_env() {
    local docker_dir="${INSTALL_DIR}/docker"
    local env_file="${docker_dir}/.env"

    if [[ ! -f "$env_file" ]]; then
        # 从 Nexus 下载 .env.example 作为模板
        local env_example_url="${NEXUS_GITHUB_CONTENT}/langgenius/dify/refs/heads/main/docker/.env.example"
        curl -fsSL "$env_example_url" -o "$env_file" || true
    fi

    if [[ ! -f "$env_file" ]]; then
        warn ".env 文件未找到，使用默认配置"
        cat > "$env_file" <<-EOF
# Dify 基础配置
SECRET_KEY=$(openssl rand -base64 42)
INIT_PASSWORD=difyai123
EOF
    fi

    # 生成 SECRET_KEY（如果没设置）
    if ! grep -q "SECRET_KEY" "$env_file" 2>/dev/null; then
        echo "# Generated by deploy.sh" >> "$env_file"
        echo "SECRET_KEY=$(openssl rand -base64 42)" >> "$env_file"
    fi

    info ".env 配置完成: ${env_file}"
}

# ========== 启动服务 ==========
start_services() {
    local docker_dir="${INSTALL_DIR}/docker"

    info "拉取镜像并启动 Dify..."
    cd "$docker_dir"
    docker compose pull
    docker compose up -d
    cd - >/dev/null

    info "等待服务启动..."
    sleep 5

    # 检查服务状态
    if docker compose -f "${docker_dir}/docker-compose.yaml" ps --services --filter "status=running" | grep -q "api"; then
        info "Dify 部署完成！"
        echo ""
        echo "========================================"
        echo "  访问地址: http://<服务器IP>/install"
        echo "  管理后台: http://<服务器IP>/console"
        echo "========================================"
        echo ""
        # 获取服务器 IP
        local ip
        ip=$(ip route get 1 | awk '{print $NF;exit}' 2>/dev/null || hostname -I | awk '{print $1}')
        echo "  本机访问: http://localhost/install"
        [[ -n "$ip" ]] && echo "  局域网访问: http://${ip}/install"
        echo ""
    else
        warn "部分服务可能未启动，请检查: docker compose -f ${docker_dir}/docker-compose.yaml ps"
    fi
}

# ========== 显示帮助 ==========
show_help() {
    cat <<-EOF
用法: $0 [版本] [安装目录]

参数:
  版本         Dify release tag (如 1.2.0), 默认 latest
  安装目录     部署路径, 默认 /opt/dify

示例:
  $0                         # 安装最新版到 /opt/dify
  $0 1.2.0                   # 安装指定版本
  $0 latest /data/dify       # 安装到自定义目录

环境变量覆盖:
  NEXUS_RAW_GITHUB           Nexus GitHub release 代理地址
  NEXUS_GITHUB_CONTENT       Nexus GitHub raw 代理地址
  NEXUS_API_GITHUB           Nexus GitHub API 代理地址
EOF
    exit 0
}

# ========== main ==========
main() {
    if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
        show_help
    fi

    echo "=========================================="
    echo "  Dify Docker Compose 部署脚本"
    echo "=========================================="
    echo ""

    check_prereqs
    get_version
    download_dify
    setup_env
    start_services
}

main "$@"
