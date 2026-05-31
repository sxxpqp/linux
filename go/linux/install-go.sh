#!/bin/bash

set -e

VERSION="1.26.2"
OS="linux"
ARCH=$(uname -m)

# 架构转换
case $ARCH in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        echo "❌ 不支持的架构: $ARCH"
        exit 1
        ;;
esac

BINARY="go${VERSION}.${OS}-${ARCH}.tar.gz"
URL="https://golang.google.cn/dl/${BINARY}"
INSTALL_DIR="/usr/local"   # 解压后自动生成 /usr/local/go
PROFILE="/etc/profile.d/go.sh"

echo "==========================================="
echo "  安装 Go ${VERSION} ${OS}/${ARCH}"
echo "==========================================="

# 检查是否已安装
if command -v go &>/dev/null; then
    CURRENT=$(go version | awk '{print $3}' | sed 's/go//')
    echo "⚠️  已安装 Go ${CURRENT}，是否覆盖安装？[y/N]"
    read -r confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && echo "取消安装" && exit 0
fi

# 下载
echo ""
echo "⬇️  下载 ${BINARY}..."
if curl -fsSL --connect-timeout 15 -o /tmp/${BINARY} "${URL}"; then
    echo "✅ 下载成功"
else
    echo "❌ 下载失败，请检查网络"
    exit 1
fi

# 解压安装
echo ""
echo "📦 解压安装到 ${INSTALL_DIR}/go..."
sudo rm -rf ${INSTALL_DIR}/go
sudo tar -C ${INSTALL_DIR} -xzf /tmp/${BINARY}
rm -f /tmp/${BINARY}

# 配置环境变量
echo ""
echo "⚙️  配置环境变量..."
cat > ${PROFILE} << 'PROFILE_EOF'
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export GOBIN=$GOPATH/bin
export PATH=$PATH:$GOROOT/bin:$GOBIN
# Go 模块与代理全局配置
export GO111MODULE=on
export GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy/,direct
export GONOSUMDB="*"
export GOPRIVATE="*.wishfoxs.com"

PROFILE_EOF

source ${PROFILE}

# 配置 Go 代理
echo ""
echo "🔧 配置 Go 代理..."
go env -w GO111MODULE=on
go env -w GOPROXY=https://goproxy.cn,https://mirrors.aliyun.com/goproxy/,direct
go env -w GONOSUMDB="*"
go env -w GOPRIVATE="*.wishfoxs.com"

# 验证
echo ""
echo "==========================================="
echo "✅ 安装完成"
echo "==========================================="
go version
echo ""
echo "Go 环境配置："
go env GOROOT
go env GOPATH
go env GOPROXY
echo ""
echo "⚠️  执行以下命令使环境变量立即生效："
echo "   source /etc/profile.d/go.sh"
echo "go install sigs.k8s.io/kubebuilder/v4@latest"