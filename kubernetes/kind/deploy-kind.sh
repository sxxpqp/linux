#!/usr/bin/env bash
# 系统: Linux / Windows Git Bash / WSL2 (GNU Make + Docker Linux containers)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kind/deploy-kind.sh
# 用法: bash kubernetes/kind/deploy-kind.sh up (在完整仓库中执行，或 make kind-up)
set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''
export KIND_EXPERIMENTAL_PROVIDER=docker
# 仅 Git Bash 需要防止 docker.exe 的容器内路径被转换为 Windows 路径。
case "${OSTYPE:-}" in
    msys*|cygwin*) export MSYS_NO_PATHCONV=1 ;;
esac

action=${1:-help}
name=${KIND_NAME:-linux-lab}
workers=${WORKERS:-0}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export PATH="$HOME/.local/bin:$PATH"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "缺少 $1，请先安装；kind 可运行 make kind-install（无需 Go）。"; }

if [[ "$action" == help ]]; then
    cat <<'EOF'
在 Linux / WSL2 / Windows Git Bash 中进入仓库根目录运行：
前置依赖：Bash、GNU Make、kubectl，以及可用的 Docker Linux containers。
Windows 使用 Docker Desktop（Linux containers 模式）；Linux 使用 Docker Engine。
  make kind-install                  下载并校验 kind v0.33.0（无需 Go）
  make kind-up                       创建/恢复集群，kindnet + ingress-nginx，master 映射 80/443
  make kind-up WORKERS=2              创建 1 control-plane + 2 worker（已有集群不改拓扑）
  make kind-up workers=2              同上，WORKERS/workers 均支持，冲突值会报错
  make kind-status                   查看节点、Pod 和 StorageClass
  make kind-ingress                  检查 ingress-nginx 就绪与 master 的 80/443 映射
  make kind-check FILE=path/to.yaml   服务端 dry-run，校验实际 API/准入规则
  make kind-apply FILE=path/to.yaml   部署到指定 kind 集群
  make kind-load IMAGE=app:test       加载宿主 Docker 中已有的镜像
  make kind-logs                     导出诊断日志到当前目录的新临时目录
  make kind-down                     输入集群名确认后删除，包含集群内数据
  make kind-uninstall                kind-down 的别名，只删除集群，保留 Docker/kind 工具
  make -s kind-config                仅输出 kubeconfig 路径（不需要 Docker 在线）
  make kind-use                      合并 kind 配置并切换 kubectl 当前 context
  make kind-unuse                    恢复 kind-use 前的 context，不需要 Docker 在线
当前终端切换到测试集群（Bash / Zsh / Git Bash / WSL）：
  make kind-use
  kubectl config current-context
取消切换，恢复先前的 context：
  make kind-unuse
use/unuse 修改 kubeconfig，不修改终端环境变量，不需要 eval。
默认操作 ~/.kube/config；已设置 KUBECONFIG 时操作该单个文件，不支持多文件列表。
kind-use 首次切换前备份目标文件；重复切换仍保留最初的恢复点。
可选 KIND_NAME=linux-lab；KIND_NODE_IMAGE 指定上游 kindest/node 镜像。
kind-up 使用独立 ~/.kube/kind-<集群名>.config；只有 kind-use 才切换当前配置。
默认 kindnet + local-path + ingress-nginx；Ingress 使用 ingressClassName: nginx。
复用 docker/kind/ingress-nginx.yaml；master 映射宿主机 80/443，无需 port-forward。
宿主机监听 0.0.0.0:80/443；端口须空闲，局域网可达性取决于宿主机防火墙。
旧集群若没有端口映射，须确认后 kind-down 再 kind-up；脚本不自动删除重建。
13.8 GB 内存建议先单节点；资源上限在 Docker Desktop / WSL 设置中调整。
check/apply 支持 YAML 文件或目录；CRD 需先安装，Jenkins $VARS 模板需先渲染。
EOF
    exit 0
fi
[[ "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail 'KIND_NAME 只能包含小写字母、数字和中间连字符。'
config="${HOME}/.kube/kind-${name}.config"
# 关闭 MSYS 路径转换后，原生 kind.exe/kubectl.exe 必须接收 Windows 路径。
case "${OSTYPE:-}" in
    msys*|cygwin*) config=$(cygpath -m "$config") ;;
esac
if [[ "$action" == config ]]; then
    [[ -f "$config" ]] || fail '没有测试集群 kubeconfig，请先 make kind-up。'
    printf '%s\n' "$config"
    exit 0
fi
if [[ "$action" == use || "$action" == unuse ]]; then
    need kubectl
    target=${KUBECONFIG:-${HOME}/.kube/config}
    separator=:
    case "${OSTYPE:-}" in
        msys*|cygwin*) separator=';'; target=$(cygpath -u "$target") ;;
    esac
    # 多文件合并时 kubectl 的写入目标不唯一，不猜测要修改哪个文件。
    [[ "$target" != *"$separator"* ]] || fail 'KUBECONFIG 是多文件列表；请先 unset KUBECONFIG 后重试。'
    [[ ! -d "$target" && ! -L "$target" ]] || fail 'kubeconfig 目标是目录或符号链接，请指定普通文件。'
    mkdir -p -- "$(dirname -- "$target")"
    target="$(cd -- "$(dirname -- "$target")" && pwd)/$(basename -- "$target")"
    [[ "$target" != *"$separator"* ]] || fail 'kubeconfig 路径含列表分隔符，无法安全合并。'
    state="${target}.kind-use.previous-context"
    cli_target=$target
    case "${OSTYPE:-}" in
        msys*|cygwin*) cli_target=$(cygpath -m "$target") ;;
    esac
    if [[ "$action" == unuse ]]; then
        [[ -f "$state" ]] || fail '没有 kind-use 恢复记录，未修改配置。'
        previous=$(cat -- "$state")
        if [[ -n "$previous" ]]; then
            kubectl --kubeconfig "$cli_target" config use-context "$previous"
        else
            kubectl --kubeconfig "$cli_target" config unset current-context
        fi
        rm -- "$state"
        echo '已恢复切换前的 context；kind 配置仍保留，可再次 make kind-use。'
        exit 0
    fi
    [[ -f "$config" ]] || fail '没有测试集群 kubeconfig，请先 make kind-up。'
    kubectl --kubeconfig "$config" --context "kind-$name" config view --minify >/dev/null \
        || fail "kind 配置缺少有效的 kind-${name} context，未修改目标配置。"
    # 临时合并文件含凭据，使用受限权限，不把 raw 配置打印到终端。
    umask 077
    merged=$(mktemp "${target}.kind-use.XXXXXX")
    trap 'rm -f -- "$merged"' EXIT
    cli_merged=$merged
    case "${OSTYPE:-}" in
        msys*|cygwin*) cli_merged=$(cygpath -m "$merged") ;;
    esac
    KUBECONFIG="${config}${separator}${cli_target}" kubectl config view --raw --flatten > "$merged"
    kubectl --kubeconfig "$cli_merged" config use-context "kind-$name" >/dev/null
    if [[ ! -e "$state" ]]; then
        previous=$(kubectl --kubeconfig "$cli_target" config view -o jsonpath='{.current-context}')
        # 保留原始文件供人工恢复；取消切换只恢复 context，不丢弃之后的配置修改。
        if [[ -f "$target" ]]; then
            backup=$(mktemp "${target}.before-kind-use.XXXXXX")
            cp -- "$target" "$backup"
            printf '原配置备份：%s\n' "$backup"
        fi
        printf '%s\n' "$previous" > "$state"
    fi
    mv -f -- "$merged" "$target"
    trap - EXIT
    printf '已切换到 kind-%s（配置：%s）。取消切换：make kind-unuse\n' "$name" "$target"
    exit 0
fi
case "$action" in
    install)
        bash "$root/kubernetes/kind/install-kind.sh" --version v0.33.0
        exit 0 ;;
    up|status|check|apply|load|logs|down|ingress) ;;
    *) fail "未知动作: $action（运行 help 查看用法）" ;;
esac
need kind
need docker
docker info >/dev/null 2>&1 || fail 'Docker 不可用，请先启动 Docker，并确认当前用户有权限。'
[[ $(docker info --format '{{.OSType}}') == linux ]] || fail '需要 Docker Linux containers。'
kube() { kubectl --kubeconfig "$config" --context "kind-$name" "$@"; }
check_ingress_ports() {
    local port bindings
    for port in 80 443; do
        bindings=$(docker port "${name}-control-plane" "${port}/tcp") \
            || fail "master 缺少 ${port} 端口映射；确认数据可删除后 make kind-down KIND_NAME=${name}，再 make kind-up KIND_NAME=${name} WORKERS=${workers}。"
        grep -Eq ":${port}$" <<<"$bindings" \
            || fail "master 未映射宿主机 ${port}；端口映射不能原地补齐，请确认后重建集群。"
    done
}

if [[ "$action" == down ]]; then
    [[ -t 0 ]] || fail '删除需要交互确认，请在终端运行。'
    read -r -p "删除集群及其中全部数据，输入集群名 $name 确认: " answer
    [[ "$answer" == "$name" ]] || fail '未确认，已取消。'
    kind delete cluster --name "$name" --kubeconfig "$config"
    exit 0
fi

if [[ "$action" == up ]]; then
    need kubectl
    [[ "$workers" =~ ^[0-2]$ ]] || fail 'WORKERS 允许 0、1、2（适用于小内存测试环境）。'
    clusters=$(kind get clusters)
    if ! grep -Fxq "$name" <<<"$clusters"; then
        echo '[1/4] 创建 kind 集群...'
        args=(create cluster --name "$name" --kubeconfig "$config" --retain --wait 180s)
        [[ -z ${KIND_NODE_IMAGE:-} ]] || args+=(--image "$KIND_NODE_IMAGE")
        mkdir -p -- "$(dirname -- "$config")"
        # kind 从 stdin 读取配置，避免在仓库留下临时 YAML。
        {
            printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\n'
            printf 'containerdConfigPatches:\n- |\n  [plugins."io.containerd.grpc.v1.cri".registry]\n    config_path = "/etc/containerd/certs.d"\n'
            if [[ $(docker info --format '{{.CgroupVersion}}') == 1 ]]; then
                echo '检测到 cgroup v1：为测试节点设置 failCgroupV1=false；宿主建议升级 cgroup v2。' >&2
                printf 'kubeadmConfigPatches:\n- |\n  kind: KubeletConfiguration\n  failCgroupV1: false\n'
            fi
            printf 'nodes:\n- role: control-plane\n'
            printf '  labels:\n    ingress-ready: "true"\n'
            printf '  extraPortMappings:\n  - containerPort: 80\n    hostPort: 80\n    listenAddress: "0.0.0.0"\n    protocol: TCP\n  - containerPort: 443\n    hostPort: 443\n    listenAddress: "0.0.0.0"\n    protocol: TCP\n'
            for ((i=0; i<workers; i++)); do printf '%s\n' '- role: worker'; done
        } | kind "${args[@]}" --config -
    else
        echo '[1/4] 集群已存在，保留现有拓扑。'
        check_ingress_ports
        nodes=$(kind get nodes --name "$name")
        [[ -n "$nodes" ]] || fail '集群没有节点。'
        while IFS= read -r node; do
            state=$(docker inspect --format '{{.State.Status}}' "$node")
            case "$state" in
                running) ;;
                exited|created)
                    echo "启动停止的测试节点: $node"
                    docker start "$node" || fail "$node 启动失败，请查看 docker inspect $node 和 docker logs $node；未删除集群。" ;;
                *) fail "$node 状态为 $state，请先检查 Docker；未删除集群。" ;;
            esac
            ready=false
            for ((attempt=0; attempt<30; attempt++)); do
                if docker exec "$node" test -s /etc/kubernetes/kubelet.conf 2>/dev/null; then
                    ready=true
                    break
                fi
                sleep 2
            done
            [[ "$ready" == true ]] || fail "$node 初始化不完整，请先 make kind-logs 检查；需要重建时 make kind-down 会要求确认。"
        done <<<"$nodes"
        kind export kubeconfig --name "$name" --kubeconfig "$config"
        ready=false
        for ((attempt=0; attempt<30; attempt++)); do
            if kube --request-timeout=2s get --raw=/readyz >/dev/null 2>&1; then
                ready=true
                break
            fi
            sleep 2
        done
        [[ "$ready" == true ]] || fail 'API 尚未就绪或上次初始化中断，请运行 make kind-logs 检查；未自动删除或重建集群。'
        kube -n kube-system get daemonset/kindnet deployment/coredns >/dev/null \
            || fail '上次 kind 初始化未完成（缺少 kindnet/CoreDNS）；请检查日志，确认后使用 make kind-down 重建。'
    fi
    check_ingress_ports
    echo '[2/4] 复用仓库 mirrors.sh 配置节点镜像加速...'
    nodes=$(kind get nodes --name "$name")
    [[ -n "$nodes" ]] || fail '集群没有节点。'
    while IFS= read -r node; do
        # kind 自带 containerd；不在容器内运行宿主机 install.sh。
        docker exec "$node" grep -Eq 'config_path[[:space:]]*=.*[/]etc/containerd/certs.d' /etc/containerd/config.toml \
            || fail "$node 未启用 certs.d，请检查 kind 节点镜像的 containerd 配置。"
        docker exec -i "$node" bash < "$root/docker/containerd/mirrors.sh"
    done <<<"$nodes"
    echo '[3/4] 等待 CNI、节点与 DNS 就绪...'
    kube -n kube-system rollout status daemonset/kindnet --timeout=180s
    kube wait --for=condition=Ready nodes --all --timeout=180s
    kube -n kube-system rollout status deployment/coredns --timeout=180s
    legacy_ingress=$(kube -n kind-ingress get deployment traefik --ignore-not-found -o name)
    [[ -z "$legacy_ingress" ]] \
        || fail '此集群仍有旧 Traefik；请确认数据后 kind-down 再 kind-up，不自动删除旧控制器。'
    echo '[4/4] 安装并等待 ingress-nginx 就绪...'
    kube label node "${name}-control-plane" ingress-ready=true --overwrite
    manifest="$root/docker/kind/ingress-nginx.yaml"
    case "${OSTYPE:-}" in
        msys*|cygwin*) manifest=$(cygpath -m "$manifest") ;;
    esac
    kube apply -f "$manifest"
    kube -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
    kube get nodes -o wide
    kube get ingressclass nginx
    printf '独立 kubeconfig: %s\n' "$config"
    echo '入口已就绪：宿主机 80/443 → master → ingress-nginx；直接访问 http://127.0.0.1 或 https://127.0.0.1，按业务 Ingress 提供 Host。'
    exit 0
fi

[[ -f "$config" ]] || fail '没有测试集群 kubeconfig，请先 make kind-up。'
case "$action" in
    status)
        need kubectl
        kube get nodes -o wide
        kube get pods -A
        kube get storageclass
        kube get ingressclass
        kube -n ingress-nginx get deployment,service ;;
    ingress)
        need kubectl
        check_ingress_ports
        kube -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
        kube get ingressclass nginx
        echo '入口直接监听宿主机 80/443，无需持续运行本命令；按业务 Ingress 设置 Host。' ;;
    check|apply)
        need kubectl
        [[ -n ${FILE:-} && -e "$FILE" ]] || fail '请指定存在的 FILE=文件或目录。'
        args=(apply -f "$FILE")
        [[ "$action" != check ]] || args+=(--dry-run=server)
        kube "${args[@]}" ;;
    load)
        [[ -n ${IMAGE:-} ]] || fail '请指定 IMAGE=app:tag。'
        kind load docker-image --name "$name" "$IMAGE" ;;
    logs)
        logdir=$(mktemp -d "./kind-${name}-logs.XXXXXX")
        kind export logs --name "$name" "$logdir" ;;
esac
