#!/usr/bin/env bash
# 系统: macOS / Linux 控制机，Docker kind 测试集群
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubesphere/kind-3.4.1/install.sh
# 用法: bash install.sh kind|mirrors|ks-install|deploy；也可使用同名 make 命令。
set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
KIND_NAME=${KIND_NAME:-kubesphere-341}
KUBE_CONFIG=${KUBE_CONFIG:-$HOME/.kube/kind-$KIND_NAME.config}
PASSWORD_FILE=${PASSWORD_FILE:-$HOME/.kube/$KIND_NAME.admin-password}
TOOLS_DIR=${TOOLS_DIR:-$HOME/.cache/linux-kubesphere-341/bin}
KIND_BIN="$TOOLS_DIR/kind"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) KIND_BIN="$TOOLS_DIR/kind.exe"; export MSYS_NO_PATHCONV=1 ;; esac
export KIND_EXPERIMENTAL_PROVIDER=docker
INSTALLER_SOURCE=${INSTALLER_SOURCE:-registry.cn-beijing.aliyuncs.com/kubesphereio/ks-installer:v3.4.1}
INSTALLER_IMAGE=docker.io/kubesphere/ks-installer:v3.4.1
K=(kubectl --kubeconfig "$KUBE_CONFIG" --context "kind-$KIND_NAME")

# 安装固定版本的 kind 工具。
ensure_kind() {
  bash "$ROOT/kubernetes/kind/install-kind.sh" --version v0.17.0 --bin-dir "$TOOLS_DIR"
}

# 1. 创建集群；已有集群保留，等待 API 就绪。
create_cluster() {
  ensure_kind
  echo '检查依赖: kubectl、Docker'
  command -v kubectl >/dev/null || { echo 'ERROR: 未找到 kubectl，请先安装 kubectl 并确认它位于当前用户的 PATH 中。' >&2; exit 1; }
  command -v docker >/dev/null || { echo 'ERROR: 未找到 docker；kind 需要 Docker，不可仅使用宿主机 containerd。' >&2; exit 1; }
  docker info >/dev/null || { echo 'ERROR: Docker 不可用，请检查 docker info 的报错和 Docker 服务状态。' >&2; exit 1; }
  echo "检查 kind 集群: $KIND_NAME"
  clusters=$("${KIND_BIN}" get clusters) || { echo 'ERROR: kind get clusters 失败，请检查上方输出。' >&2; exit 1; }
  if printf '%s\n' "$clusters" | grep -Fxq -- "${KIND_NAME}"; then
    echo '集群已存在，保留现有节点和数据。'
    state=$(docker inspect --format '{{.State.Status}}' "${KIND_NAME}-control-plane")
    case "$state" in running) ;; exited|created) docker start "${KIND_NAME}-control-plane";;
      *) echo "ERROR: 节点状态 $state，请检查 Docker，未重建集群。" >&2; exit 1;; esac
    "${KIND_BIN}" export kubeconfig --name "${KIND_NAME}" --kubeconfig "${KUBE_CONFIG}"
  else
    mkdir -p "$(dirname "${KUBE_CONFIG}")"
    "${KIND_BIN}" create cluster --name "${KIND_NAME}" --config "${DIR}/kind.yaml" \
      --kubeconfig "${KUBE_CONFIG}" --retain --wait 180s
  fi
  ready=false; for ((i=0; i<30; i++)); do
    if "${K[@]}" --request-timeout=2s get --raw=/readyz >/dev/null 2>&1; then ready=true; break; fi
    sleep 2
  done; test "$ready" = true || { echo 'ERROR: API 尚未就绪；未自动删除或重建集群。' >&2; exit 1; }
  check_cluster
}

# 只读检查，避免操作错误版本或端口不匹配的集群。
check_cluster() {
  test -f "${KUBE_CONFIG}" || { echo 'ERROR: 缺少 kubeconfig，请先 make kind。' >&2; exit 1; }
  docker inspect "${KIND_NAME}-control-plane" >/dev/null 2>&1 \
    || { echo 'ERROR: 测试集群不存在或 Docker 不可用，请先 make kind。' >&2; exit 1; }
  version=$("${K[@]}" get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
  case "$version" in v1.24.*) ;; *) echo "ERROR: 要求 Kubernetes 1.24，当前为 $version。" >&2; exit 1;; esac
  docker port "${KIND_NAME}-control-plane" 30880/tcp | grep -Fxq '127.0.0.1:30880' \
    || { echo 'ERROR: 集群缺少预期 30880 映射，不自动删除重建。' >&2; exit 1; }
}

# 2. 为全部节点设置加速源，逐台验证后再继续。
configure_mirrors() {
  ensure_kind
  check_cluster
  nodes=$("${KIND_BIN}" get nodes --name "${KIND_NAME}")
  test -n "$nodes" || { echo 'ERROR: 未找到 kind 节点。' >&2; exit 1; }
  for node in $nodes; do
    echo "设置镜像加速源: $node"
    docker exec -i "$node" bash -s -- --kind-config < "${ROOT}/docker/containerd/mirrors.sh"
    docker exec "$node" systemctl --no-pager restart containerd
    docker exec "$node" crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null
    docker exec "$node" crictl --runtime-endpoint unix:///run/containerd/containerd.sock \
      --image-endpoint unix:///run/containerd/containerd.sock pull docker.io/library/busybox:1.36
    "${K[@]}" wait --for=condition=Ready "node/$node" --timeout=180s
  done
}

# 加载安装器镜像，清单保持上游 image。
load_installer() {
  ensure_kind
  check_cluster
  docker image inspect "${INSTALLER_SOURCE}" >/dev/null 2>&1 || docker pull "${INSTALLER_SOURCE}"
  docker tag "${INSTALLER_SOURCE}" "${INSTALLER_IMAGE}"
  "${KIND_BIN}" load docker-image "${INSTALLER_IMAGE}" --name "${KIND_NAME}"
}

# 3. 生成本机密码并提交 ks-installer 清单。
apply_installer() {
  load_installer
  command -v openssl >/dev/null
  command -v python3 >/dev/null
  umask 077; mkdir -p "$(dirname "${PASSWORD_FILE}")"
  if ! test -e "${PASSWORD_FILE}"; then
    password="Ks341-7$(openssl rand -hex 16)"
    (set -o noclobber; printf '%s\n' "$password" > "${PASSWORD_FILE}")
  fi
  test -s "${PASSWORD_FILE}" || { echo 'ERROR: 密码文件为空。' >&2; exit 1; }
  password_json=$(python3 -c 'import json,pathlib,re,sys; p=pathlib.Path(sys.argv[1]).read_text().rstrip("\n"); assert 8 <= len(p) <= 64 and all(re.search(x,p) for x in ("[a-z]","[A-Z]","[0-9]")), "密码必须为 8~64 字符并包含大小写字母和数字"; print(json.dumps(p))' "${PASSWORD_FILE}")
  "${K[@]}" apply -f "${DIR}/installer.yaml"
  "${K[@]}" wait --for=condition=Established crd/clusterconfigurations.installer.kubesphere.io --timeout=30s
  KS_ADMIN_PASSWORD_JSON="$password_json" awk \
    '/^[ ]+jwtSecret:/ {printf "    adminPassword: %s\n", ENVIRON["KS_ADMIN_PASSWORD_JSON"]} {print}' \
    "${DIR}/cluster-configuration.yaml" | "${K[@]}" apply -f -
}

# 等待核心服务和监控就绪。
wait_ready() {
  check_cluster
  "${K[@]}" -n kubesphere-system wait --for=jsonpath='{.status.core.status}'=enabled clusterconfiguration/ks-installer --timeout=600s
  for app in ks-apiserver ks-console ks-controller-manager; do
    "${K[@]}" -n kubesphere-system rollout status "deployment/$app" --timeout=600s
  done
  "${K[@]}" -n kubesphere-monitoring-system wait --for=condition=Ready pods --all --timeout=600s
}

# 查看节点、Pod、PVC 和控制台。
show_status() {
  check_cluster
  "${K[@]}" get nodes -o wide
  "${K[@]}" get pods -A
  "${K[@]}" get pvc -A
  "${K[@]}" -n kubesphere-system get service ks-console
}

# 查看安装器日志。
show_logs() {
  check_cluster
  "${K[@]}" -n kubesphere-system logs deployment/ks-installer --tail=80
}

# 显示登录入口和密码文件位置。
show_login() {
  printf '%s\n' '控制台：http://127.0.0.1:30880' '用户名：admin' "密码文件：${PASSWORD_FILE}"
  test -s "${PASSWORD_FILE}" || { echo 'ERROR: 密码文件不存在或为空。' >&2; exit 1; }
}

# 交互确认后删除测试集群。
delete_cluster() {
  ensure_kind
  test -t 0 || { echo 'ERROR: 删除需要在交互终端确认。' >&2; exit 1; }
  read -r -p "删除 ${KIND_NAME} 及全部集群数据，输入集群名确认: " answer
  test "$answer" = "${KIND_NAME}" || { echo '已取消。' >&2; exit 1; }
  "${KIND_BIN}" delete cluster --name "${KIND_NAME}" --kubeconfig "${KUBE_CONFIG}"
}

# 切换或恢复默认 context。
switch_context() {
  KIND_NAME="${KIND_NAME}" KUBECONFIG="${KUBECONFIG:-}" bash "${ROOT}/kubernetes/kind/deploy-kind.sh" "$1"
}

install_ks() {
  check_cluster
  nodes=$("${KIND_BIN}" get nodes --name "${KIND_NAME}")
  test -n "$nodes"
  for node in $nodes; do
    docker exec "$node" test -s /etc/containerd/certs.d/docker.io/hosts.toml \
      || { echo 'ERROR: 请先执行 make mirrors。' >&2; exit 1; }
  done
  apply_installer
  wait_ready
  show_login
}

# 主流程：三个阶段串行执行，任何命令失败立即停止。
main() {
  case "${1:-help}" in
    kind|up) echo '[1/3] 安装 kind 并创建集群'; create_cluster ;;
    mirrors) echo '[2/3] 设置全部节点镜像源'; configure_mirrors ;;
    ks-install) echo '[3/3] 安装 KubeSphere'; install_ks ;;
    deploy)
      main kind
      main mirrors
      main ks-install ;;
    tools) ensure_kind ;; guard) check_cluster ;;
    images) load_installer ;; install) apply_installer ;;
    status) show_status ;; wait) wait_ready ;;
    logs) show_logs ;; login) show_login ;;
    use|unuse) switch_context "$1" ;;
    down) delete_cluster ;;
    help|-h|--help)
      printf '%s\n' '1. make kind        安装 kind 并创建集群' \
        '2. make mirrors     设置全部节点镜像加速源' \
        '3. make ks-install  安装 KubeSphere 并等待就绪' \
        'make deploy         按以上三步串行执行' \
        '辅助命令: status wait logs login use unuse down' \
        '依赖: Docker、kubectl、curl、SHA256 工具、openssl、Python 3（无需 Go）' \
        '控制台: http://127.0.0.1:30880；login 显示密码文件位置' ;;
    *) echo "ERROR: 未知命令 $1" >&2; return 1 ;;
  esac
}
main "$@"
