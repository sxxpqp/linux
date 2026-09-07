#!/usr/bin/env bash
# 系统: Ubuntu | CentOS
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/centos/config-time-locale.sh
# 用法: curl -fsSLk https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/centos/config-time-locale.sh -o config-time-locale.sh && bash config-time-locale.sh

set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
LOCALE_NAME="${LOCALE_NAME:-zh_CN.UTF-8}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-true}"
ENABLE_NTP="${ENABLE_NTP:-true}"
DRY_RUN="false"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

usage() {
  cat <<'EOF'
用法: bash config-time-locale.sh [选项]

默认配置:
  timezone: Asia/Shanghai
  locale:   zh_CN.UTF-8
  ntp:      自动启用(systemd-timesyncd 或 chrony/chronyd)

选项:
  --timezone=ZONE       设置时区,默认 Asia/Shanghai
  --locale=LOCALE       设置系统地区,默认 zh_CN.UTF-8
  --no-install          不安装 locale / ntp 相关包,只使用现有命令配置
  --no-ntp              不启用 NTP 自动同步
  --dry-run             只打印将执行的命令
  -h, --help            显示帮助

示例:
  bash config-time-locale.sh
  bash config-time-locale.sh --timezone=Asia/Shanghai --locale=zh_CN.UTF-8
  bash config-time-locale.sh --timezone=UTC --locale=en_US.UTF-8 --no-ntp
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --timezone=*) TIMEZONE="${1#*=}" ;;
    --locale=*) LOCALE_NAME="${1#*=}" ;;
    --no-install) INSTALL_PACKAGES="false" ;;
    --no-ntp) ENABLE_NTP="false" ;;
    --dry-run) DRY_RUN="true" ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数: $1"; usage >&2; exit 1 ;;
  esac
  shift
done

run() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '  [dry-run]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

run_shell() {
  if [ "$DRY_RUN" = "true" ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    sh -c "$*"
  fi
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请用 root 执行: sudo bash $0"
    exit 1
  fi
}

detect_os() {
  if [ ! -r /etc/os-release ]; then
    err "缺少 /etc/os-release,无法识别系统"
    exit 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_FAMILY="unknown"

  case "$OS_ID" in
    ubuntu|debian)
      OS_FAMILY="debian"
      ;;
    centos|rhel|rocky|almalinux|ol|fedora)
      OS_FAMILY="rhel"
      ;;
    *)
      err "暂不支持系统: $OS_ID $OS_VERSION_ID"
      exit 1
      ;;
  esac
}

pkg_install() {
  [ "$INSTALL_PACKAGES" = "true" ] || return 0
  [ $# -gt 0 ] || return 0

  case "$OS_FAMILY" in
    debian)
      run env DEBIAN_FRONTEND=noninteractive apt-get update
      run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        run dnf install -y "$@"
      else
        run yum install -y "$@"
      fi
      ;;
  esac
}

locale_exists() {
  local target
  target=$(printf '%s' "$LOCALE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/')
  locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/' | grep -qx "$target"
}

language_pack_for_locale() {
  case "$LOCALE_NAME" in
    zh_CN*|zh_SG*) echo "glibc-langpack-zh" ;;
    en_US*|en_GB*) echo "glibc-langpack-en" ;;
    ja_JP*) echo "glibc-langpack-ja" ;;
    ko_KR*) echo "glibc-langpack-ko" ;;
    *) echo "" ;;
  esac
}

install_locale_packages() {
  case "$OS_FAMILY" in
    debian)
      pkg_install locales
      ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        local pack
        pack=$(language_pack_for_locale)
        if [ -n "$pack" ]; then
          pkg_install "$pack"
        else
          pkg_install glibc-all-langpacks || true
        fi
      else
        pkg_install glibc-common
      fi
      ;;
  esac
}

configure_timezone() {
  log "[1/4] 配置时区: $TIMEZONE"

  if [ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    err "时区不存在: /usr/share/zoneinfo/$TIMEZONE"
    echo "可用示例: Asia/Shanghai, UTC, Asia/Hong_Kong"
    exit 1
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    run timedatectl set-timezone "$TIMEZONE"
  else
    run ln -snf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    run_shell "printf '%s\n' '$TIMEZONE' > /etc/timezone"
  fi

  ok "timezone=$TIMEZONE"
}

configure_locale_debian() {
  install_locale_packages

  if ! locale_exists; then
    if [ -f /etc/locale.gen ]; then
      run_shell "grep -q '^${LOCALE_NAME} UTF-8' /etc/locale.gen || sed -i 's/^# *${LOCALE_NAME} UTF-8/${LOCALE_NAME} UTF-8/' /etc/locale.gen"
    fi
    run locale-gen "$LOCALE_NAME"
  fi

  if command -v update-locale >/dev/null 2>&1; then
    run update-locale "LANG=$LOCALE_NAME" "LC_ALL=$LOCALE_NAME"
  else
    run_shell "printf 'LANG=%s\nLC_ALL=%s\n' '$LOCALE_NAME' '$LOCALE_NAME' > /etc/default/locale"
  fi
}

configure_locale_rhel() {
  install_locale_packages

  if ! locale_exists && command -v localedef >/dev/null 2>&1; then
    local input charmap
    input="${LOCALE_NAME%%.*}"
    charmap="${LOCALE_NAME#*.}"
    run localedef -c -f "$charmap" -i "$input" "$LOCALE_NAME" || warn "localedef 生成 $LOCALE_NAME 失败,继续尝试 localectl"
  fi

  if command -v localectl >/dev/null 2>&1; then
    run localectl set-locale "LANG=$LOCALE_NAME"
  else
    run_shell "printf 'LANG=%s\nLC_ALL=%s\n' '$LOCALE_NAME' '$LOCALE_NAME' > /etc/locale.conf"
  fi
}

configure_locale() {
  log "[2/4] 配置地区/语言: $LOCALE_NAME"

  case "$OS_FAMILY" in
    debian) configure_locale_debian ;;
    rhel) configure_locale_rhel ;;
  esac

  ok "locale=$LOCALE_NAME"
}

has_unit() {
  systemctl list-unit-files "$1" >/dev/null 2>&1
}

configure_ntp() {
  log "[3/4] 配置时间同步"

  if [ "$ENABLE_NTP" != "true" ]; then
    warn "已跳过 NTP 配置(--no-ntp)"
    return 0
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    run timedatectl set-ntp true || true
  fi

  if [ "$OS_FAMILY" = "debian" ] && has_unit systemd-timesyncd.service; then
    run systemctl enable --now systemd-timesyncd.service
    ok "NTP=systemd-timesyncd"
    return 0
  fi

  case "$OS_FAMILY" in
    debian)
      pkg_install chrony
      run systemctl enable --now chrony.service
      ok "NTP=chrony"
      ;;
    rhel)
      pkg_install chrony
      run systemctl enable --now chronyd.service
      ok "NTP=chronyd"
      ;;
  esac
}

show_result() {
  log "[4/4] 当前配置"

  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl || true
  else
    date
  fi

  echo
  echo "locale:"
  locale | grep -E '^(LANG|LC_ALL)=' || true

  echo
  echo "验证命令:"
  echo "  timedatectl"
  echo "  locale | grep -E '^(LANG|LC_ALL)='"
}

need_root
detect_os
ok "OS=$OS_ID $OS_VERSION_ID family=$OS_FAMILY"

configure_timezone
configure_locale
configure_ntp
show_result

ok "时间、时区、地区配置完成"
