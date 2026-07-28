#!/usr/bin/env bash
# 系统: Linux (systemd)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/cir-docker/install.sh
# 用法: curl -sL "https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/cir-docker/install.sh" -o install.sh && bash install.sh [--cri-socket unix:///run/cri-dockerd.sock] [--pause-image dockerhub.ihome.sxxpqp.top:8443/pause:3.9]

set -euo pipefail

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

CRI_DOCKER_VERSION="0.3.22"
CRI_SOCKET="unix:///run/cri-dockerd.sock"
PAUSE_IMAGE="registry.aliyuncs.com/google_containers/pause:3.9"
DOWNLOAD_BASE_URL="https://chfs.sxxpqp.top:8443/chfs/shared/docker/cri-docker"
WORKDIR=""

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

err() {
  echo "[ERROR] $*" >&2
}

cleanup() {
  if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
    rm -rf "${WORKDIR}"
  fi
}

usage() {
  cat <<'EOF'
用法:
  bash install.sh [选项]

选项:
  --cri-socket <unix-socket>   kubelet / kubeadm 使用的 CRI socket
  --pause-image <image>        cri-dockerd 使用的 pause 镜像
  --version <version>          cri-dockerd 版本，默认 0.3.22
  -h, --help                   显示帮助

说明:
  1. 只安装 cri-dockerd，不覆盖主 kubelet.service
  2. kubeadm 初始化/加节点时请显式传:
     --cri-socket unix:///run/cri-dockerd.sock
EOF
}

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    err "请使用 root 运行"
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    err "缺少命令: ${cmd}"
    exit 1
  fi
}

detect_arch() {
  local raw_arch
  raw_arch="$(uname -m)"
  case "${raw_arch}" in
    x86_64|amd64)
      echo "amd64"
      ;;
    aarch64|arm64)
      echo "arm64"
      ;;
    *)
      err "暂不支持架构: ${raw_arch}"
      exit 1
      ;;
  esac
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --cri-socket)
        [ $# -ge 2 ] || { err "--cri-socket 缺少参数"; exit 1; }
        CRI_SOCKET="$2"
        shift 2
        ;;
      --pause-image)
        [ $# -ge 2 ] || { err "--pause-image 缺少参数"; exit 1; }
        PAUSE_IMAGE="$2"
        shift 2
        ;;
      --version)
        [ $# -ge 2 ] || { err "--version 缺少参数"; exit 1; }
        CRI_DOCKER_VERSION="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  done
}

preflight() {
  require_root
  require_cmd curl
  require_cmd tar
  require_cmd install
  require_cmd systemctl
  require_cmd sed
  require_cmd grep

  if ! systemctl list-unit-files --type=service --no-legend 2>/dev/null | grep -q '^docker\.service'; then
    err "未检测到 docker.service，请先安装 Docker"
    exit 1
  fi
}

download_and_install_binary() {
  local arch pkg_name pkg_url pkg_file extracted_bin
  arch="$(detect_arch)"
  pkg_name="cri-dockerd-${CRI_DOCKER_VERSION}.${arch}.tgz"
  pkg_url="${DOWNLOAD_BASE_URL}/${pkg_name}"

  WORKDIR="$(mktemp -d /tmp/cri-dockerd.XXXXXX)"
  trap cleanup EXIT

  pkg_file="${WORKDIR}/${pkg_name}"
  extracted_bin="${WORKDIR}/cri-dockerd/cri-dockerd"

  log "下载 cri-dockerd: ${pkg_url}"
  curl -fsSLk "${pkg_url}" -o "${pkg_file}"

  log "解压 cri-dockerd"
  tar -xzf "${pkg_file}" -C "${WORKDIR}"

  if [ ! -f "${extracted_bin}" ]; then
    err "解压后未找到 ${extracted_bin}"
    exit 1
  fi

  log "安装二进制到 /usr/bin/cri-dockerd"
  install -m 0755 "${extracted_bin}" /usr/bin/cri-dockerd
}

write_cri_dockerd_units() {
  log "写入 cri-dockerd systemd unit"
  cat > /etc/systemd/system/cri-docker.service <<EOF
[Unit]
Description=CRI Interface for Docker Application Container Engine
Documentation=https://docs.mirantis.com
After=network-online.target firewalld.service docker.service
Wants=network-online.target
Requires=cri-docker.socket

[Service]
Type=notify
ExecStart=/usr/bin/cri-dockerd --container-runtime-endpoint fd:// --pod-infra-container-image ${PAUSE_IMAGE}
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/cri-docker.socket <<'EOF'
[Unit]
Description=CRI Docker Socket for the API
PartOf=cri-docker.service

[Socket]
ListenStream=%t/cri-dockerd.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF
}

start_services() {
  log "重新加载 systemd 并启动 cri-dockerd"
  systemctl daemon-reload
  systemctl enable --now cri-docker.socket cri-docker.service
}

print_summary() {
  log "安装完成"
  echo
  echo "验证命令:"
  echo "  systemctl --no-pager --full status cri-docker.service"
  echo "  systemctl --no-pager --full status cri-docker.socket"
  echo "  ls -l /run/cri-dockerd.sock"
  echo
  echo "kubeadm 用法:"
  echo "  kubeadm init --cri-socket ${CRI_SOCKET} ..."
  echo "  kubeadm join --cri-socket ${CRI_SOCKET} ..."
  echo
  echo "说明:"
  echo "  本脚本不会改 kubelet.service / kubelet drop-in。"
  echo "  如果当前节点已经 join 过集群，请改 kubeadm 的运行参数后再重启 kubelet，或重新 join。"
}

main() {
  parse_args "$@"
  preflight
  download_and_install_binary
  write_cri_dockerd_units
  start_services
  print_summary
}

main "$@"
