#!/usr/bin/env bash
# 系统: Linux (systemd) - 任意发行版,只装二进制
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/nerdctl/install.sh
# 用法: curl -sLk <URL> -o install.sh && bash install.sh [选项]
#
# 安装 nerdctl(containerd 官方 CLI,docker 命令的替代品)。
# 二进制方式,从 GitHub release 拉(走 Nexus raw-github 代理)。
#
# 默认会问"是否别名 docker?":
#   选 y → 写入 /etc/profile.d/nerdctl-alias.sh,内容 `alias docker=nerdctl`
#          交互 shell 里跑 docker xxx 实际跑 nerdctl xxx
#          ★ 不影响 /usr/local/bin/docker 真实二进制,跟已有 docker 不冲突
#   选 n → 仅装 nerdctl,不写 alias
#
# 加 --alias-docker / --no-alias-docker 可跳过提问,适合自动化场景。

set -euo pipefail

# ============================================================
# 默认值 / 参数解析
# ============================================================
NERDCTL_VERSION=""                # 不传则从 GitHub API 探测最新稳定版
INSTALL_DIR="/usr/local/bin"
ALIAS_DOCKER=""                   # 空=问;true=直接装;false=直接跳
EXTRA_TOOLS="false"               # 解压包里其他工具(buildkit、CNI 等),默认只装 nerdctl

# Nexus 代理(见 CLAUDE.md "Nexus 仓库映射")
NEXUS_RAW_GITHUB="${NEXUS_RAW_GITHUB:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-github}"
NEXUS_RAW_GITHUB_API="${NEXUS_RAW_GITHUB_API:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-github-api}"

usage() {
  cat <<'EOF'
用法: bash install.sh [选项]

选项:
  --version=VER           nerdctl 版本(例 2.0.0,默认从 GitHub API 探测最新)
  --install-dir=DIR       安装目录,默认 /usr/local/bin
  --alias-docker          直接写 alias docker=nerdctl 到 /etc/profile.d/,不问
  --no-alias-docker       不写 alias,不问
  --extra-tools           连同 tar 里的其他工具一起装(buildctl 等,谨慎)
  -h, --help              显示帮助

外网环境(无 Nexus):
  NEXUS_RAW_GITHUB=https://github.com \
  NEXUS_RAW_GITHUB_API=https://api.github.com \
  bash install.sh

示例:
  bash install.sh                                  # 交互式问别名,装最新
  bash install.sh --version=2.0.0 --alias-docker   # 装 2.0.0 + 别名
  bash install.sh --no-alias-docker                # 装最新,不别名
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version=*) NERDCTL_VERSION="${1#*=}" ;;
    --install-dir=*) INSTALL_DIR="${1#*=}" ;;
    --alias-docker) ALIAS_DOCKER="true" ;;
    --no-alias-docker) ALIAS_DOCKER="false" ;;
    --extra-tools) EXTRA_TOOLS="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

# ============================================================
# 1/5 前置检查
# ============================================================
log "[1/5] 前置检查"

command -v curl >/dev/null || { err "curl 不存在"; exit 1; }
command -v tar  >/dev/null || { err "tar 不存在"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  err "需要 root(要写入 $INSTALL_DIR)"
  exit 1
fi

# 架构判断
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  NERDCTL_ARCH="amd64" ;;
  aarch64|arm64) NERDCTL_ARCH="arm64" ;;
  armv7l)  NERDCTL_ARCH="arm-v7" ;;
  *) err "不支持的架构: $ARCH"; exit 1 ;;
esac
ok "架构: $ARCH → $NERDCTL_ARCH"

# containerd 是否在跑(警告但不强制)
if ! command -v containerd >/dev/null 2>&1; then
  warn "containerd 二进制不存在 — nerdctl 装好后还是不能用(需要 containerd 在跑)"
elif ! systemctl is-active --quiet containerd 2>/dev/null; then
  warn "containerd 服务未启动 — 装完后 systemctl start containerd"
else
  ok "containerd 正在运行"
fi

# ============================================================
# 2/5 确定版本(没传就探测最新)
# ============================================================
log "[2/5] 确定 nerdctl 版本"

if [ -z "$NERDCTL_VERSION" ]; then
  log "  从 GitHub API 探测最新稳定版..."
  TAG=$(curl -fsSLk "$NEXUS_RAW_GITHUB_API/repos/containerd/nerdctl/releases/latest" 2>/dev/null \
        | grep -oE '"tag_name":\s*"v[0-9]+\.[0-9]+\.[0-9]+"' \
        | head -1 \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
  if [ -z "$TAG" ]; then
    err "无法探测最新版本,请 --version=X.Y.Z 显式指定"
    err "  手动看:https://github.com/containerd/nerdctl/releases/latest"
    exit 1
  fi
  NERDCTL_VERSION="${TAG#v}"
  ok "最新稳定版: v$NERDCTL_VERSION"
else
  NERDCTL_VERSION="${NERDCTL_VERSION#v}"
  ok "指定版本: v$NERDCTL_VERSION"
fi

# ============================================================
# 3/5 下载 + 校验
# ============================================================
log "[3/5] 下载 nerdctl"

TARBALL="nerdctl-${NERDCTL_VERSION}-linux-${NERDCTL_ARCH}.tar.gz"
URL="$NEXUS_RAW_GITHUB/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/${TARBALL}"
TMP=$(mktemp -d /tmp/nerdctl.XXXXXX)
trap "rm -rf $TMP" EXIT

log "  $URL"
if ! curl -fsSLk "$URL" -o "$TMP/$TARBALL"; then
  err "下载失败"
  err "  - 检查 Nexus 可达:curl -kI $NEXUS_RAW_GITHUB/"
  err "  - 或外网直连:NEXUS_RAW_GITHUB=https://github.com bash install.sh ..."
  err "  - 或换版本:--version=<其他可用版本>"
  exit 1
fi

SIZE=$(du -h "$TMP/$TARBALL" | awk '{print $1}')
ok "下载完成($SIZE)"

# ============================================================
# 4/5 安装到 INSTALL_DIR
# ============================================================
log "[4/5] 安装到 $INSTALL_DIR"

tar -xzf "$TMP/$TARBALL" -C "$TMP"

# 默认只装 nerdctl;--extra-tools 才装包里所有二进制
if [ "$EXTRA_TOOLS" = "true" ]; then
  warn "--extra-tools:tar 包里 buildctl / runc 等也会装,可能跟系统已有冲突"
  find "$TMP" -maxdepth 2 -type f -executable -not -name "*.gz" | while read -r f; do
    install -m 0755 "$f" "$INSTALL_DIR/$(basename "$f")"
    ok "装: $(basename "$f")"
  done
else
  if [ ! -f "$TMP/nerdctl" ]; then
    err "tar 包里没找到 nerdctl 二进制"
    ls -la "$TMP"
    exit 1
  fi
  install -m 0755 "$TMP/nerdctl" "$INSTALL_DIR/nerdctl"
  ok "nerdctl 已安装到 $INSTALL_DIR/nerdctl"
fi

# 验证
"$INSTALL_DIR/nerdctl" --version

# ============================================================
# 5/5 docker shell alias(默认问)
# 写到 /etc/profile.d/nerdctl-alias.sh,只在交互 shell 生效
# 不动 /usr/local/bin/docker,真实 docker 二进制(如果有)继续走 PATH
# ============================================================
log "[5/5] docker shell alias"

ALIAS_FILE="/etc/profile.d/nerdctl-alias.sh"

if [ -z "$ALIAS_DOCKER" ]; then
  echo
  cat <<EOF
  是否在交互 shell 里把 docker 别名为 nerdctl?

    实现:写入 $ALIAS_FILE,内容 alias docker='nerdctl'
    ✓ 好处:登录 shell 跑 docker ps / docker pull 实际跑 nerdctl
    ✓ 无冲突:跟 /usr/local/bin/docker 真实二进制(如果有)不冲突
              因为 alias 只在交互 shell 生效,脚本 / systemd unit 仍走 PATH
    ✗ 想关:删 $ALIAS_FILE,重新登录即可

EOF
  # 用 /dev/tty 让 curl | bash 模式也能交互
  if [ -e /dev/tty ]; then
    read -rp "  写 docker alias?[Y/n]: " answer </dev/tty || answer=""
  else
    read -rp "  写 docker alias?[Y/n]: " answer || answer=""
  fi
  case "$answer" in
    [Nn]*) ALIAS_DOCKER="false" ;;
    *)     ALIAS_DOCKER="true" ;;
  esac
fi

if [ "$ALIAS_DOCKER" = "true" ]; then
  cat > "$ALIAS_FILE" <<'EOF'
# nerdctl 安装时配的 docker 别名
# 让交互 shell 下 `docker xxx` 实际跑 `nerdctl xxx`
# 删除此文件 + 重新登录 即可关闭别名
alias docker='nerdctl'
EOF
  chmod 0644 "$ALIAS_FILE"
  ok "alias 已写入 $ALIAS_FILE"
  warn "生效方式(任选其一):"
  echo "    a. 重新登录 / 新开一个终端"
  echo "    b. 当前 shell 立即生效:source $ALIAS_FILE"
else
  ok "跳过 docker alias"
fi

# ============================================================
# 结束
# ============================================================
echo
log "==== 安装完成 ===="

cat <<EOF

常用命令:
  nerdctl ps                        # 看容器(默认 namespace = default)
  nerdctl -n k8s.io ps              # 看 K8s 拉的容器(K8s containerd namespace 是 k8s.io)
  nerdctl images
  nerdctl pull nginx
  nerdctl run -d --name web nginx
  nerdctl logs web

nerdctl 跟 containerd 通过 /run/containerd/containerd.sock 通信,
确保 containerd 服务在跑:
  systemctl status containerd

跟 docker CLI 的差别:
  - 默认看不到 K8s 拉的容器(K8s 用 k8s.io namespace),要加 -n k8s.io
  - 没有 docker-compose,要用 nerdctl compose(语法相同)
  - --restart=always 行为略有不同,要 nerdctl 文档确认

EOF
