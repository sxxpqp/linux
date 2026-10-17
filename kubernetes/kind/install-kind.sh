#!/usr/bin/env bash
# 系统: Linux / macOS / Windows Git Bash；WSL 使用 Linux 二进制
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kind/install-kind.sh
# 用法: bash install-kind.sh [--version v0.33.0] [--bin-dir "$HOME/.local/bin"]
set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''
VERSION=v0.33.0
BIN_DIR="$HOME/.local/bin"
# 默认走仓库现有 Nexus release 代理；外网可显式设置为 https://github.com。
DOWNLOAD_BASE=${KIND_DOWNLOAD_BASE:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-github}
fail() { echo "ERROR: $*" >&2; exit 1; }
while (($#)); do
  case "$1" in
    --version|--bin-dir)
      (($# >= 2)) || fail "$1 缺少参数"
      case "$1" in --version) VERSION=$2 ;; --bin-dir) BIN_DIR=$2 ;; esac
      shift 2 ;;
    --help|-h)
      echo '用法: bash install-kind.sh [--version v0.33.0] [--bin-dir DIR]'
      echo '支持 Linux/macOS amd64、arm64，Windows Git Bash amd64；不依赖 Go 或管理员权限。'
      exit 0 ;;
    *) fail "未知参数 $1" ;;
  esac
done
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && -n "$BIN_DIR" ]] || fail '版本须为 vX.Y.Z，安装目录不能为空'
case "$(uname -s)" in
  Linux) os=linux ;; Darwin) os=darwin ;;
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  *) fail '不支持的系统；Windows 请使用 Git Bash 或 WSL' ;;
esac
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
  *) fail '仅支持 amd64 和 arm64' ;;
esac
[[ "$os-$arch" != windows-arm64 ]] || fail '当前安装入口使用 Windows amd64 发布包；ARM Windows 可使用 WSL'
binary=kind
[[ "$os" != windows ]] || binary=kind.exe
target="$BIN_DIR/$binary"
if [[ -x "$target" ]] && "$target" version | grep -F "kind $VERSION " >/dev/null; then
  echo "kind 已安装: $target ($VERSION)"
  exit 0
fi
command -v curl >/dev/null || fail '缺少 curl'
if command -v sha256sum >/dev/null; then
  SHA=(sha256sum)
elif command -v shasum >/dev/null; then
  SHA=(shasum -a 256)
else
  fail '缺少 sha256sum 或 shasum'
fi
mkdir -p "$BIN_DIR"
WORK=$(mktemp -d "$BIN_DIR/.kind-install.XXXXXXXX")
trap 'rm -rf "$WORK"' EXIT
asset="kind-$os-$arch"
url="${DOWNLOAD_BASE%/}/kubernetes-sigs/kind/releases/download/$VERSION/$asset"
echo "下载 kind $VERSION ($os/$arch)"
curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 "$url" -o "$WORK/$binary"
curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 "$url.sha256sum" -o "$WORK/checksum"
expected=$(awk 'NR == 1 {print $1}' "$WORK/checksum")
[[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || fail '上游 SHA256 文件格式错误'
actual=$("${SHA[@]}" "$WORK/$binary" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || fail 'SHA256 校验失败，未安装'
chmod +x "$WORK/$binary"
"$WORK/$binary" version | grep -F "kind $VERSION " >/dev/null || fail '下载的 kind 版本不匹配'
if [[ -e "$target" ]]; then
  backup=$(mktemp "$BIN_DIR/kind.backup.XXXXXXXX")
  cp -p "$target" "$backup"
  echo "原二进制备份: $backup"
fi
mv "$WORK/$binary" "$target"
echo "安装完成: $target"
printf '当前终端使用: export PATH="%s:$PATH"\n' "$BIN_DIR"
