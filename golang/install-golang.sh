#!/bin/sh
#
# install-golang.sh — 阿里云镜像安装 Go 官方预编译包
#
# 系统: Linux (不挑发行版) | GO_OS=darwin 可选
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/golang/install-golang.sh
# 用法: curl -sL <下载 URL> | sh                              # 装最新稳定版到 /usr/local/go
#       curl -sL <下载 URL> | GO_VERSION=1.24 sh -            # 装 1.24 系列最高补丁版
#       curl -sL <下载 URL> | GO_VERSION=1.27.2 GO_ARCH=arm64 sh -
# 源:   https://mirrors.aliyun.com/golang/
#
# 环境变量:
#   GO_VERSION      latest(默认) | 系列号 1.24 | 精确 1.27.2
#   GO_OS           linux(默认) | darwin
#   GO_ARCH         空=自动探测; amd64 arm64 armv6l 386 mips mipsle mips64 mips64le
#                   ppc64le s390x riscv64 loong64
#   GO_ROOT         /usr/local(默认), 实际安装到 $GO_ROOT/go
#   GO_MIRROR       https://mirrors.aliyun.com(默认), 可换其它同源镜像站
#   GO_URL          完整 tarball URL; 指定后不再查索引, 也不再读 OS/ARCH/VERSION
#   GO_DOWNLOADER   auto(默认) | curl | wget
#   GO_SET_GOPROXY  1 = 额外把 GOPROXY/GOSUMDB 写进 /etc/profile.d/go.sh
#
# 实现要点:
#   - 纯 POSIX /bin/sh, 无 bash 依赖, 可 curl|sh 直跑; 脚本源走 stdin, 全程不做 </dev/null
#   - 不用 getgo: aliyun 镜像里的 installer_linux 运行时仍要回连 go.dev/dl, 国内不可达
#   - curl 与 wget 都支持(实测)。注意 curl 是首选: 只有 curl 能报真实 HTTP 状态码,
#     wget-only 环境只能靠"下载失败"报错, 404 的提示信息不如 curl 精确
#   - 阿里云镜像没有可用的 .sha256 文件(实测 404), 完整性校验改成四道门:
#       HTTP 200 -> gzip 魔数 1f8b -> 体积 >20MB -> tar 根目录为 go/ -> 解包后 go version 可执行
#   - VERSION 唯一来源是 tarball 文件名里的 goX.Y.Z; 版本解析结果只用于拼 URL,
#     备份比较一律用它, 避免"解析出最新 1.27 却覆盖已装的 1.24"这种降级静默
set -eu
export LC_ALL=C
umask 022

GO_VERSION="${GO_VERSION:-latest}"
GO_OS="${GO_OS:-linux}"
GO_ARCH="${GO_ARCH:-}"
GO_ROOT="${GO_ROOT:-/usr/local}"
GO_MIRROR="${GO_MIRROR:-https://mirrors.aliyun.com}"
GO_URL="${GO_URL:-}"
GO_DOWNLOADER="${GO_DOWNLOADER:-auto}"
GO_SET_GOPROXY="${GO_SET_GOPROXY:-0}"
PROFILE_FILE="${PROFILE_FILE:-/etc/profile.d/go.sh}"
INDEX_URL="$GO_MIRROR/golang/"

tmp=""
VERSION=""
DL="curl"

log() { printf '[golang] %s\n' "$*"; }
die() { printf '[golang] ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
cleanup() { [ -n "$tmp" ] && rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

# ---------------- 1. 安装目标可写 ----------------

[ -d "$GO_ROOT" ] || mkdir -p "$GO_ROOT" 2>/dev/null || true
[ -d "$GO_ROOT" ] && [ -w "$GO_ROOT" ] || \
  die "无法写入 $GO_ROOT (当前用户 $(id -un)), 请用 sudo -E sh 或以有权限的账户运行"

# ---------------- 2. 下载工具探测 (curl > wget) ----------------

case "$GO_DOWNLOADER" in
  auto)
    if have curl; then DL=curl
    elif have wget; then DL=wget
    else die "需要 curl 或 wget 其中之一; 安装: yum install -y curl / apt-get install -y curl"
    fi ;;
  curl) have curl || die "GO_DOWNLOADER=curl 但系统没有 curl" ;;
  wget) have wget || die "GO_DOWNLOADER=wget 但系统没有 wget" ;;
  *) die "GO_DOWNLOADER 仅支持 auto|curl|wget (当前: $GO_DOWNLOADER)" ;;
esac

dl() { # $1=url $2=dest
  if [ "$DL" = curl ]; then
    curl -fL -sS -# --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 900 -o "$2" "$1"
  else
    wget -q -O "$2" --tries=3 --timeout=60 "$1"
  fi
}

http_code() { # 打印 200 / 000(不可达或非 2xx)
  # 只走 curl: 只有 curl 能返回真实 HTTP 状态码。
  # 不能用 wget --spider 顶替 —— 它在无 CA 的容器里会因 TLS 验证失败而误报"包不存在",
  # 现象是明明能用 wget 下载成功, 脚本却卡在预检查阶段。
  if ! have curl; then
    printf '000'
    return 0
  fi
  c=$(curl -sIL -o /dev/null -w '%{http_code}' --connect-timeout 15 --max-time 40 "$1" 2>/dev/null || true)
  [ -n "$c" ] || c=000
  printf '%s' "$c"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/go-install.XXXXXX" 2>/dev/null || {
        d="${TMPDIR:-/tmp}/go-install.$$"; mkdir -p "$d"; printf '%s' "$d"; })

log "OS=$GO_OS ARCH=${GO_ARCH:-<auto>} ROOT=$GO_ROOT MIRROR=$GO_MIRROR DOWNLOADER=$DL"

# 拉镜像索引并打印候选版本(已排序). 索引是单层扁平目录, 形如 href="go1.27.2.linux-amd64.tar.gz"
# 注意: 不做 HTTP 状态码预检查, 直接下载。wget 通道拿不到真实状态码(见 http_code 注释),
#      靠下载失败本身报错即可, 少一次网络往返。
fetch_index() {
  dl "$INDEX_URL" "$tmp/index.html" \
    || die "无法访问镜像索引 $INDEX_URL; 可换 GO_MIRROR 或显式指定 GO_VERSION"
  grep -oE "href=\"go[0-9]+\.[0-9]+\.[0-9]+\.$GO_OS-[^\"']+\"" "$tmp/index.html" \
    | sed "s/.*href=\"go//;s/\.$GO_OS-.*//" | sort -uV
}

# ---------------- 3. 探测架构 / 拼 URL ----------------

case "$GO_OS" in
  linux|darwin) ;;
  *) die "GO_OS 仅支持 linux|darwin (当前: $GO_OS); Windows 请直接下 https://mirrors.aliyun.com/golang/ 的 .zip" ;;
esac

if [ -z "$GO_ARCH" ]; then
  m=$(uname -m)
  case "$m" in
    x86_64|amd64)          GO_ARCH=amd64 ;;
    aarch64|arm64)         GO_ARCH=arm64 ;;
    armv6*|armv7*|armhf)   GO_ARCH=armv6l ;; # go 的 armv7 包名沿用 armv6l (GOARM=6 ABI)
    i[3-6]86)              GO_ARCH=386 ;;
    mips|mipsle|mips64|mips64le|ppc64le|s390x|riscv64|loong64|ppc64) GO_ARCH=$m ;;
    *) die "无法识别的架构 $m, 请用 GO_ARCH=amd64|arm64|armv6l|386|mips|mipsle|mips64|mips64le|ppc64le|s390x|riscv64|loong64 指定" ;;
  esac
fi
log "目标: $GO_OS-$GO_ARCH"

if [ -z "$GO_URL" ]; then
  case "$GO_VERSION" in go*) GO_VERSION=${GO_VERSION#go} ;; esac
  case "$GO_VERSION" in
    ''|latest)
      log "未指定 GO_VERSION, 从镜像索引解析最新稳定版 ..."
      RESOLVED=$(fetch_index | tail -1)
      ;;
    [0-9]*.[0-9]*.[0-9]*)
      RESOLVED="$GO_VERSION"
      log "使用精确版本: $RESOLVED"
      ;;
    [0-9]*.[0-9]*)
      log "GO_VERSION=$GO_VERSION 是系列号, 解析该系列最高补丁版本 ..."
      RESOLVED=$(fetch_index | grep "^$GO_VERSION\." | tail -1)
      ;;
    *) die "GO_VERSION 格式不合法: '$GO_VERSION' (示例: latest | 1.24 | 1.27.2)" ;;
  esac
  # 索引不可达时 fetch_index 在子 shell 里 die, 主脚本靠这个空值检查兜底退出
  [ -n "$RESOLVED" ] || die "镜像索引里找不到 $GO_OS 版的 $GO_VERSION, 换 GO_VERSION/GO_OS 或 GO_MIRROR"
  log "解析为: $RESOLVED"
  GO_URL="$GO_MIRROR/golang/go$RESOLVED.$GO_OS-$GO_ARCH.tar.gz"
else
  log "使用 GO_URL: $GO_URL (跳过索引查询)"
fi

TAR_NAME=$(basename "$GO_URL")
log "包名: $TAR_NAME"

# 版本唯一来源: 包名里的 goX.Y.Z(而不是上面的解析结果), 后面备份比较全靠它
VERSION=$(printf '%s' "$TAR_NAME" | grep -oE 'go[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^go//')
[ -n "$VERSION" ] || die "无法从包名解析版本号: $TAR_NAME, 请显式指定 GO_VERSION"

# ---------------- 4. 预检查 + 下载 ----------------

if have curl; then
  c=$(http_code "$GO_URL")
  [ "$c" = 200 ] || die "包不存在或不可达: $GO_URL (HTTP $c); 换 GO_VERSION/GO_ARCH 或 GO_MIRROR"
else
  log "无 curl, 跳过 HTTP 状态码预检查, 直接下载"
fi

tarball="$tmp/$TAR_NAME"
log "开始下载 ..."
dl "$GO_URL" "$tarball" || \
  die "下载失败: $GO_URL; 若确认 URL 正确, 多半是网络或镜像问题, 可换 GO_MIRROR 重试"
log "下载完成, 校验中 ..."

# ---------------- 5. 完整性校验 ----------------

magic=$(od -An -N2 -tx1 "$tarball" 2>/dev/null | tr -d ' \n')
[ "$magic" = 1f8b ] || \
  die "文件不是 gzip 压缩包(前 2 字节: ${magic:-empty}), 多半是镜像返回的 HTML 错误页; 检查 URL 或换 GO_MIRROR"

size=$(wc -c < "$tarball" | tr -d ' ')
[ "$size" -gt 20000000 ] || \
  die "压缩包仅 ${size} 字节, 明显被截断或不是 Go 安装包(正常约 60-90MB)"

root=$(tar -tzf "$tarball" 2>/dev/null | head -1)
case "$root" in
  go/|go/*) log "tar 结构正常" ;;
  *) die "压缩包根目录是 '$root', 预期 'go/'" ;;
esac

if have sha256sum; then
  log "sha256: $(sha256sum "$tarball" | awk '{print $1}')"
elif have shasum; then
  log "sha256: $(shasum -a 256 "$tarball" | awk '{print $1}')"
else
  log "未找到 sha256sum/shasum, 跳过校验和打印"
fi

# ---------------- 6. 安装 ----------------

log "安装 $VERSION 到 $GO_ROOT/go ..."
if [ -d "$GO_ROOT/go" ]; then
  oldver="$("$GO_ROOT/go/bin/go" version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || true)"
  if [ -n "$oldver" ] && [ "$oldver" = "$VERSION" ]; then
    log "已存在同版本 $VERSION, 解包覆盖"
  else
    n=1
    while [ -d "$GO_ROOT/go.prev$n" ]; do n=$((n+1)); done
    log "发现已有 Go ${oldver:-unknown}, 先移到 $GO_ROOT/go.prev$n 备份(确认无误后可手动删除)"
    mv "$GO_ROOT/go" "$GO_ROOT/go.prev$n"
  fi
fi

tar -xzf "$tarball" -C "$GO_ROOT"

GO_BIN="$GO_ROOT/go/bin/go"
[ -x "$GO_BIN" ] || die "解包后找不到 $GO_BIN"
"$GO_BIN" version

# ---------------- 7. 写 PATH ----------------

PATHLINE="export PATH=\"$GO_ROOT/go/bin:\$PATH\""
if [ -d /etc/profile.d ] && [ -w /etc/profile.d ]; then
  printf '%s\n' "$PATHLINE" > "$PROFILE_FILE"
  if [ "$GO_SET_GOPROXY" = 1 ]; then
    printf 'export GOPROXY=https://goproxy.cn,direct\nexport GOSUMDB=sum.golang.google.cn\n' >> "$PROFILE_FILE"
  fi
  log "已写入 $PROFILE_FILE"
else
  log "无 $PROFILE_FILE 写权限, 请手动加入 shell 配置:"
  log "  $PATHLINE"
fi

log "完成: $("$GO_BIN" version)"
log "来源: $GO_URL"
log "新开 shell 生效, 或先执行: $PATHLINE"
log "国内拉 module 还需配置: go env -w GOPROXY=https://goproxy.cn,direct GOSUMDB=sum.golang.google.cn"
