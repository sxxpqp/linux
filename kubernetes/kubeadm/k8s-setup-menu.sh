#!/usr/bin/env bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeadm/k8s-setup-menu.sh
# ================================================================
#  K8s 集群一键安装菜单
#  作者: sxxpqp 运智运维
# ================================================================

set -uo pipefail

# ---- curl|bash 执行时 stdin 被管道占用，用 /dev/tty 作为交互终端 ----
# 所有 read 命令通过 TTY 变量显式指定输入源
TTY_INPUT=/dev/tty

BASE="https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/main/kubernetes"
URL_KERNEL="${BASE}/kubeadm/k8skerneloptimize.sh"
URL_K8S="${BASE}/kubeadm/installk8s.sh"
URL_HELM="${BASE}/helm/install-helm.sh"

# ================================================================
#  全局配置变量（按需修改）
# ================================================================

# ---- 私有镜像仓库 ----
REGISTRY="huball.ihome.sxxpqp.top:8443"
NEXUS_HELM="https://nexus.ihome.sxxpqp.top:8443/repository"
NEXUS_LONGHORN="https://nexus.ihome.sxxpqp.top:8443/repository/hwlm-longhorn"
NEXUS_INGRESS_NGINX="https://nexus.ihome.sxxpqp.top:8443/repository/helmingress-nginx"

# ---- K8s 网络配置 ----
POD_CIDR="10.244.0.0/16"          # Pod 网段
K8S_API_PORT="6443"                # API Server 端口

# ---- Cilium BGP 配置 ----
BGP_ASN="65000"                    # 本地 ASN
LB_IP_START="172.16.0.200"        # LoadBalancer IP 池起始
LB_IP_END="172.16.0.210"          # LoadBalancer IP 池结束

# ---- Cilium BGP CRD 名称 ----
BGP_CLUSTER_NAME="cilium-bgp"
BGP_PEER_NAME="cilium-peer"
BGP_ADS_NAME="bgp-ads"
LB_POOL_NAME="local-pool"

# ---- Cilium capability ----
CILIUM_CAP="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID,NET_BIND_SERVICE}"

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
C='\033[0;36m' B='\033[1m'    N='\033[0m'

info()  { echo -e "${G}[INFO]${N}  $*"; }
warn()  { echo -e "${Y}[WARN]${N}  $*"; }
err()   { echo -e "${R}[ERR ]${N}  $*"; }
title() { echo -e "\n${C}${B}━━━  $*  ━━━${N}"; }
pause() { read -rp "$(echo -e "${Y}按回车继续...${N}")" < ${TTY_INPUT} < ${TTY_INPUT}; }

run_url() {
    local desc="$1" url="$2"
    local tmpfile
    title "$desc"
    info "执行: $url"

    # 先下载到临时文件再执行，避免 curl|bash 吞掉 stdin 导致 read 失效
    tmpfile=$(mktemp /tmp/k8s-run-XXXXXX.sh)
    curl -fsSLk "$url" -o "$tmpfile"
    chmod +x "$tmpfile"
    bash "$tmpfile"
    rm -f "$tmpfile"

    info "$desc 完成 ✓"
    pause
}

need_kubectl() {
    command -v kubectl &>/dev/null || { err "未找到 kubectl，请先完成步骤 1-2"; pause; return 1; }
    kubectl get nodes &>/dev/null  || { err "kubectl 无法连接集群，检查 kubeconfig"; pause; return 1; }
}

need_helm() {
    command -v helm &>/dev/null || { err "未找到 helm，请先完成步骤 3"; pause; return 1; }
}

# ================================================================
do_kernel() { run_url "① 内核参数优化" "$URL_KERNEL"; }
do_k8s()    { run_url "② 安装 Kubernetes (kubeadm)" "$URL_K8S"; }
do_helm()   { run_url "③ 安装 Helm" "$URL_HELM"; }

# ----------------------------------------------------------------
do_mirror() {
    title "④ 配置容器镜像加速源"

    # 统一私有代理地址
    PROXY="https://${REGISTRY}"

    info "开始配置 containerd 镜像加速，代理: ${PROXY}"

    # 仓库列表: "registry|upstream_server"
    REGISTRIES=(
        "docker.io|https://registry-1.docker.io"
        "registry.k8s.io|https://registry.k8s.io"
        "k8s.gcr.io|https://k8s.gcr.io"
        "gcr.io|https://gcr.io"
        "ghcr.io|https://ghcr.io"
        "quay.io|https://quay.io"
        "registry.cn-hangzhou.aliyuncs.com|https://registry.cn-hangzhou.aliyuncs.com"
    )

    for entry in "${REGISTRIES[@]}"; do
        registry="${entry%%|*}"
        upstream="${entry##*|}"
        dir="/etc/containerd/certs.d/${registry}"
        mkdir -p "$dir"
        cat > "${dir}/hosts.toml" <<EOF
server = "${upstream}"

[host."${PROXY}"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
        info "${registry} → ${PROXY} ✓"
    done

    # 确保 containerd config.toml 启用 config_path
    CONTAINERD_CFG="/etc/containerd/config.toml"
    if [[ -f "$CONTAINERD_CFG" ]]; then
        if grep -q 'config_path' "$CONTAINERD_CFG"; then
            info "containerd config_path 已配置 ✓"
        else
            warn "未检测到 config_path，自动注入..."
            sed -i '/\[plugins\."io\.containerd\.grpc\.v1\.cri"\.registry\]/a\        config_path = "/etc/containerd/certs.d"' "$CONTAINERD_CFG" \
                && info "config_path 注入成功 ✓" \
                || warn "注入失败，请手动在 [plugins.\"io.containerd.grpc.v1.cri\".registry] 下添加:\n  config_path = \"/etc/containerd/certs.d\""
        fi
    else
        warn "未找到 ${CONTAINERD_CFG}，请确认 containerd 已安装"
    fi

    info "重启 containerd..."
    systemctl restart containerd \
        && info "containerd 重启完成 ✓" \
        || warn "重启失败，请手动执行: systemctl restart containerd"

    echo ""
    echo -e "${B}已配置仓库 (均代理至 ${PROXY}):${N}"
    for entry in "${REGISTRIES[@]}"; do echo "  ${entry%%|*}"; done
    echo ""
    echo -e "${Y}验证: crictl pull docker.io/library/nginx:alpine${N}"
    pause
}

# ----------------------------------------------------------------
do_cilium() {
    title "⑤ 安装 Cilium CNI"
    need_kubectl || return
    need_helm    || return

    MASTER_IP=$(kubectl get nodes \
        --selector='node-role.kubernetes.io/control-plane' \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
    [[ -z "$MASTER_IP" ]] && read -rp "Master 节点 IP: " MASTER_IP < ${TTY_INPUT}

    echo -e "\n${B}选择 Cilium 模式:${N}"
    echo "  1) 完整模式  — 替换 kube-proxy + eBPF + Hubble UI  [推荐]"
    echo "  2) 标准模式  — 保留 kube-proxy + Hubble UI"
    read -rp "$(echo -e "${Y}请选 [1/2，默认1]: ${N}")" m; m="${m:-1}" < ${TTY_INPUT}

    helm repo add cilium ${NEXUS_HELM}/helm.cilium/ 2>/dev/null || true
    helm repo update cilium

    # 自动检测主网卡名称
    IFACE=$(ip route | awk '/default/{print $5; exit}')
    info "检测到出口网卡: ${IFACE}"

    COMMON=(
        cilium cilium/cilium
        --namespace kube-system
        --set hubble.relay.enabled=true
        --set hubble.ui.enabled=true
        --set hubble.ui.service.type=NodePort
        --set ipam.mode=cluster-pool
        --set "ipam.operator.clusterPoolIPv4PodCIDRList={${POD_CIDR}}"             --set "securityContext.capabilities.ciliumAgent=${CILIUM_CAP}"
        # 隧道模式 NAT 相关
        --set routingMode=tunnel
        --set tunnelProtocol=vxlan
        --set bpf.masquerade=true
        --set "bpf.masqueradeInterfaces=${IFACE}"
        --set nodePort.enabled=true
        --set loadBalancer.mode=snat
        --set loadBalancer.acceleration=disabled
        --set hostFirewall.enabled=false
    )

    if [[ "$m" == "1" ]]; then
        helm upgrade --install "${COMMON[@]}" \
            --set kubeProxyReplacement=true \
            --set k8sServiceHost="${MASTER_IP}" \
            --set k8sServicePort=${K8S_API_PORT}

        # 删除 kube-proxy（Cilium 完全接管）
        info "删除 kube-proxy DaemonSet..."
        kubectl delete daemonset kube-proxy -n kube-system --ignore-not-found
        kubectl delete configmap kube-proxy -n kube-system --ignore-not-found
        info "kube-proxy 已移除，由 Cilium eBPF 接管 ✓"
    else
        helm upgrade --install "${COMMON[@]}"
    fi

    info "等待 Cilium 就绪..."
    kubectl rollout status daemonset/cilium -n kube-system --timeout=120s || true
    kubectl get pods -n kube-system -l k8s-app=cilium

    # ---- 重启相关组件，确保被 Cilium CNI 正确接管 ----
    info "重启 hubble-relay / hubble-ui / coredns，确保 Pod IP 由 Cilium 分配..."
    kubectl rollout restart deployment/hubble-relay -n kube-system 2>/dev/null || true
    kubectl rollout restart deployment/hubble-ui -n kube-system 2>/dev/null || true
    kubectl rollout restart deployment/coredns -n kube-system 2>/dev/null || true
    kubectl rollout status deployment/coredns -n kube-system --timeout=60s || true

    # 等待 hubble 就绪
    sleep 10
    kubectl rollout status deployment/hubble-relay -n kube-system --timeout=60s || true
    kubectl rollout status deployment/hubble-ui -n kube-system --timeout=60s || true

    PORT=$(kubectl get svc -n kube-system hubble-ui \
        -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "未就绪")
    info "Cilium 完成 ✓  Hubble UI NodePort: ${PORT}"

    # 获取任意 worker 节点 IP 做访问提示
    WORKER_IP=$(kubectl get nodes         --selector='!node-role.kubernetes.io/control-plane'         -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
    echo ""
    echo -e "${B}Hubble UI 访问方式:${N}"
    echo "  浏览器:      http://${WORKER_IP:-<WorkerIP>}:${PORT}"
    echo "  port-forward: kubectl port-forward -n kube-system svc/hubble-ui 8080:80 --address=0.0.0.0"
    echo "  然后访问:    http://${MASTER_IP}:8080"
    pause
}

# ----------------------------------------------------------------
do_rancher() {
    title "⑥ 安装 Rancher 管理平台"
    need_kubectl || return
    need_helm    || return

    warn "Rancher 较重，单集群场景 Kuboard 已够用，多集群管理才建议安装"
    read -rp "$(echo -e "${Y}确认安装? [y/N]: ${N}")" yn < ${TTY_INPUT}
    [[ "${yn,,}" != "y" ]] && { warn "已跳过"; pause; return; }

    read -rp "Rancher 域名 (如 rancher.wishfoxs.com): " RHOST < ${TTY_INPUT}
    read -rp "Bootstrap 密码 [默认 Admin@123456]: " RPASS < ${TTY_INPUT}
    RPASS="${RPASS:-Admin@123456}"

    info "安装 cert-manager..."
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo update jetstack
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --set installCRDs=true
    kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s

    info "安装 Rancher..."
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable 2>/dev/null || true
    helm repo update rancher-stable
    helm upgrade --install rancher rancher-stable/rancher \
        --namespace cattle-system --create-namespace \
        --set hostname="${RHOST}" \
        --set bootstrapPassword="${RPASS}" \
        --set replicas=1

    kubectl rollout status deployment/rancher -n cattle-system --timeout=180s || true
    info "Rancher 完成 ✓  访问: https://${RHOST}"
    pause
}


# ----------------------------------------------------------------
do_test() {
    title "⑦ Cilium 网络连通性验证"
    need_kubectl || return

    NS="cilium-test"
    IMAGE_BUSYBOX="${REGISTRY}/library/busybox:1.36"
    IMAGE_NGINX="${REGISTRY}/library/nginx:alpine"

    echo -e "${B}选择验证方式:${N}"
    echo "  1) 快速验证  — 部署两个 Pod 互通（反亲和强制跨节点）[推荐]"
    echo "  2) 完整验证  — cilium connectivity test（需安装 cilium CLI，较慢）"
    read -rp "$(echo -e "${Y}请选 [1/2，默认1]: ${N}")" m; m="${m:-1}" < ${TTY_INPUT}

    if [[ "$m" == "2" ]]; then
        if ! command -v cilium &>/dev/null; then
            err "未找到 cilium CLI，请先安装或选择方式1"
            pause; return
        fi
        info "执行 cilium connectivity test（可能需要几分钟）..."
        cilium connectivity test
        pause; return
    fi

    # ---- 快速验证（反亲和性强制跨节点）----
    info "创建测试命名空间 ${NS}..."
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

    info "部署 server Pod (nginx)..."
    kubectl apply -n "$NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cilium-test-server
  namespace: ${NS}
  labels:
    app: cilium-test
    role: server
spec:
  containers:
  - name: nginx
    image: ${IMAGE_NGINX}
    ports:
    - containerPort: 80
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: role
            operator: In
            values:
            - client
        topologyKey: kubernetes.io/hostname
EOF

    info "部署 client Pod (busybox，反亲和与 server 强制不同节点)..."
    kubectl apply -n "$NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: cilium-test-client
  namespace: ${NS}
  labels:
    app: cilium-test
    role: client
spec:
  containers:
  - name: busybox
    image: ${IMAGE_BUSYBOX}
    command: ["sleep", "300"]
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
          - key: role
            operator: In
            values:
            - server
        topologyKey: kubernetes.io/hostname
EOF

    kubectl expose pod cilium-test-server \
        --namespace="$NS" \
        --port=80 --name=cilium-test-svc 2>/dev/null || true

    info "等待 Pod 就绪（最多90秒）..."
    kubectl wait pod cilium-test-server \
        --namespace="$NS" --for=condition=Ready --timeout=90s
    kubectl wait pod cilium-test-client \
        --namespace="$NS" --for=condition=Ready --timeout=90s

    CLIENT_NODE=$(kubectl get pod cilium-test-client -n "$NS" -o jsonpath='{.spec.nodeName}')
    SERVER_NODE=$(kubectl get pod cilium-test-server -n "$NS" -o jsonpath='{.spec.nodeName}')
    SERVER_IP=$(kubectl get pod cilium-test-server -n "$NS" -o jsonpath='{.status.podIP}')
    SVC_IP=$(kubectl get svc cilium-test-svc -n "$NS" -o jsonpath='{.spec.clusterIP}')

    echo ""
    echo -e "${B}── Pod 调度情况 ──${N}"
    echo "  client → 节点: ${CLIENT_NODE}"
    echo "  server → 节点: ${SERVER_NODE}"
    [[ "$CLIENT_NODE" != "$SERVER_NODE" ]] \
        && info "跨节点调度成功 ✓" \
        || warn "仍在同一节点（可用节点数不足2时反亲和自动退化）"

    echo ""
    echo -e "${B}── 测试1: 跨节点 Pod IP 直连 ──${N}"
    kubectl exec -n "$NS" cilium-test-client -- \
        wget -qO- --timeout=5 "http://${SERVER_IP}" \
        && info "Pod IP 直连 ✓" \
        || err "Pod IP 直连失败 ✗"

    echo ""
    echo -e "${B}── 测试2: ClusterIP Service 访问 ──${N}"
    kubectl exec -n "$NS" cilium-test-client -- \
        wget -qO- --timeout=5 "http://${SVC_IP}" \
        && info "ClusterIP Service 访问 ✓" \
        || err "ClusterIP Service 访问失败 ✗"

    echo ""
    echo -e "${B}── 测试3: DNS 解析 ──${N}"
    kubectl exec -n "$NS" cilium-test-client -- \
        nslookup cilium-test-svc."$NS".svc.cluster.local \
        && info "DNS 解析 ✓" \
        || err "DNS 解析失败 ✗"

    echo ""
    read -rp "$(echo -e "${Y}验证完成，是否清理测试资源? [Y/n]: ${N}")" clean < ${TTY_INPUT}
    clean="${clean:-y}"
    if [[ "${clean,,}" == "y" ]]; then
        kubectl delete namespace "$NS" --ignore-not-found
        info "测试资源已清理 ✓"
    else
        warn "测试资源保留在 namespace: ${NS}"
    fi
    pause
}

# ----------------------------------------------------------------

# ----------------------------------------------------------------
do_bgp() {
    title "⑧ 配置 Cilium BGP + L2 Announcement"
    need_kubectl || return

    echo -e "${Y}说明:${N}"
    echo "  BGP  — 节点间互相通告 Pod CIDR 路由，后期可接交换机"
    echo "  L2   — 同二层网络 ARP 响应 LoadBalancer IP，使其立即可访问"
    echo ""

    # ---- 检测 Cilium 安装方式 ----
    CILIUM_VALUES="/etc/cilium-values.yaml"
    CILIUM_RELEASE=$(helm list -A --filter 'cilium' -q 2>/dev/null | head -1)
    CILIUM_NS=$(helm list -A --filter 'cilium' 2>/dev/null | awk 'NR>1{print $2}' | head -1)
    CILIUM_NS="${CILIUM_NS:-kube-system}"

    echo -e "${B}检测 Cilium 安装状态:${N}"
    if [[ -n "$CILIUM_RELEASE" ]]; then
        info "检测到已有 Helm release: ${CILIUM_RELEASE} (ns: ${CILIUM_NS})"
        INSTALL_MODE="helm"
    elif kubectl get ds/cilium -n kube-system &>/dev/null; then
        warn "Cilium 以非 Helm 方式安装，将直接修改 ConfigMap"
        INSTALL_MODE="kubectl"
    else
        warn "未检测到 Cilium，将全新安装"
        INSTALL_MODE="new"
    fi
    info "模式: ${INSTALL_MODE}"

    # ---- 收集节点信息 ----
    echo ""
    echo -e "${B}当前集群节点:${N}"
    kubectl get nodes -o wide
    echo ""

    read -rp "$(echo -e "${Y}本地 ASN [默认 65000]: ${N}")" LOCAL_ASN < ${TTY_INPUT}
    LOCAL_ASN="${LOCAL_ASN:-${BGP_ASN}}"

    read -rp "$(echo -e "${Y}LoadBalancer IP 池起始 IP [默认 ${LB_IP_START}]: ${N}")" IP_START < ${TTY_INPUT}
    IP_START="${IP_START:-${LB_IP_START}}"

    read -rp "$(echo -e "${Y}LoadBalancer IP 池结束 IP [默认 ${LB_IP_END}]: ${N}")" IP_END < ${TTY_INPUT}
    IP_END="${IP_END:-${LB_IP_END}}"

    # 自动获取所有节点 IP 和名称
    NODE_IPS=($(kubectl get nodes \
        -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'))
    NODE_NAMES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))

    # 自动检测主网卡
    IFACE=$(ip route | awk '/default/{print $5; exit}')
    info "检测到出口网卡: ${IFACE}"

    echo ""
    echo -e "${B}检测到节点:${N}"
    for i in "${!NODE_NAMES[@]}"; do
        echo "  ${NODE_NAMES[$i]} → ${NODE_IPS[$i]}"
    done
    echo ""
    read -rp "$(echo -e "${Y}确认执行? [y/N]: ${N}")" yn < ${TTY_INPUT}
    [[ "${yn,,}" != "y" ]] && { warn "已取消"; pause; return; }

    # ================================================================
    # Step1: 更新 Cilium 配置（开启 BGP + L2 + NET_BIND_SERVICE）
    # ================================================================
    info "Step1: 更新 Cilium 配置..."

    helm repo add cilium ${NEXUS_HELM}/helm.cilium/ 2>/dev/null || true
    helm repo update cilium

    # 统一的 capability 配置
    CAP="${CILIUM_CAP}"

    if [[ "$INSTALL_MODE" == "helm" ]]; then
        # 导出当前 values，去掉冲突的旧 key
        helm get values "${CILIUM_RELEASE}" -n "${CILIUM_NS}" | \
            grep -v '^\s*tunnelProtocol:\|^\s*routingMode:' > "${CILIUM_VALUES}" || true

        # 追加 BGP + L2 配置
        cat >> "${CILIUM_VALUES}" << VALEOF
bgpControlPlane:
  enabled: true
l2announcements:
  enabled: true
externalIPs:
  enabled: true
routingMode: native
ipv4NativeRoutingCIDR: "${POD_CIDR}"
autoDirectNodeRoutes: true
hubble:
  relay:
    enabled: true
  ui:
    enabled: true
    service:
      type: LoadBalancer
VALEOF

        info "当前 values 文件:"
        cat "${CILIUM_VALUES}"
        echo ""

        helm upgrade "${CILIUM_RELEASE}" cilium/cilium \
            --namespace "${CILIUM_NS}" \
            -f "${CILIUM_VALUES}" \
            --set "securityContext.capabilities.ciliumAgent=${CAP}"

    elif [[ "$INSTALL_MODE" == "new" ]]; then
        MASTER_IP=$(kubectl get nodes \
            --selector='node-role.kubernetes.io/control-plane' \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
        [[ -z "$MASTER_IP" ]] && read -rp "Master 节点 IP: " MASTER_IP < ${TTY_INPUT}

        helm install cilium cilium/cilium \
            --namespace kube-system \
            --set kubeProxyReplacement=true \
            --set k8sServiceHost="${MASTER_IP}" \
            --set k8sServicePort=${K8S_API_PORT} \
            --set bgpControlPlane.enabled=true \
            --set l2announcements.enabled=true \
            --set externalIPs.enabled=true \
            --set routingMode=native \
            --set ipv4NativeRoutingCIDR="${POD_CIDR}" \
            --set autoDirectNodeRoutes=true \
            --set bpf.masquerade=true \
            --set "bpf.masqueradeInterfaces=${IFACE}" \
            --set nodePort.enabled=true \
            --set loadBalancer.mode=snat \
            --set hubble.relay.enabled=true \
            --set hubble.ui.enabled=true \
            --set "hubble.ui.service.type=LoadBalancer" \
            --set ipam.mode=cluster-pool \
            --set "ipam.operator.clusterPoolIPv4PodCIDRList={${POD_CIDR}}" \
            --set "securityContext.capabilities.ciliumAgent=${CAP}"

    else
        # kubectl 安装方式，patch configmap
        kubectl patch configmap cilium-config -n kube-system --type merge -p '{
          "data": {
            "enable-bgp-control-plane": "true",
            "enable-l2-announcements": "true",
            "routing-mode": "native",
            "ipv4-native-routing-cidr": "${POD_CIDR}",
            "auto-direct-node-routes": "true"
          }
        }'
    fi

    # ---- Step2: 重启 operator 和 cilium ----
    info "Step2: 重启 cilium-operator..."
    kubectl rollout restart deployment/cilium-operator -n kube-system
    kubectl rollout status deployment/cilium-operator -n kube-system --timeout=120s

    info "重启 cilium DaemonSet..."
    kubectl rollout restart daemonset/cilium -n kube-system
    kubectl rollout status daemonset/cilium -n kube-system --timeout=300s

    # ---- Step3: IP 池 ----
    info "Step3: 创建 LoadBalancer IP 池 ${IP_START} - ${IP_END}..."
    kubectl apply -f - <<YAML
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: ${LB_POOL_NAME}
spec:
  blocks:
  - start: "${IP_START}"
    stop: "${IP_END}"
YAML

    # ---- Step4: BGP peer 配置（所有节点互为 peer，包含 localPort）----
    info "Step4: 生成 BGP peer 配置..."

    PEERS_YAML=""
    for i in "${!NODE_NAMES[@]}"; do
        PEERS_YAML+="    - name: \"peer-${NODE_NAMES[$i]}\"\n"
        PEERS_YAML+="      peerASN: ${LOCAL_ASN}\n"
        PEERS_YAML+="      peerAddress: ${NODE_IPS[$i]}\n"
        PEERS_YAML+="      peerConfigRef:\n"
        PEERS_YAML+="        name: cilium-peer\n"
    done

    kubectl apply -f - <<YAML
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: ${BGP_CLUSTER_NAME}
spec:
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  bgpInstances:
  - name: "instance-${LOCAL_ASN}"
    localASN: ${LOCAL_ASN}
    localPort: 179
    peers:
$(echo -e "$PEERS_YAML" | sed 's/^/    /')
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: ${BGP_PEER_NAME}
spec:
  transport:
    peerPort: 179
  gracefulRestart:
    enabled: true
    restartTimeSeconds: 120
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        advertise: bgp
---
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: ${BGP_ADS_NAME}
  labels:
    advertise: bgp
spec:
  advertisements:
  - advertisementType: Service
    service:
      addresses:
      - LoadBalancerIP
  - advertisementType: PodCIDR
YAML

    # ---- Step5: L2 通告策略（匹配所有常见网卡名，兼容不同节点）----
    info "Step5: 创建 L2 通告策略..."
    kubectl apply -f - <<YAML
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default-l2
spec:
  interfaces:
  - ^eth.*
  - ^ens.*
  - ^enp.*
  - ^bond.*
  externalIPs: true
  loadBalancerIPs: true
YAML

    # ---- Step6: 防火墙放行 179 ----
    info "Step6: 放行 BGP 端口 179..."
    if command -v ufw &>/dev/null; then
        ufw allow 179/tcp 2>/dev/null && info "ufw 已放行 179/tcp ✓" || true
    fi
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --add-port=179/tcp --permanent 2>/dev/null && \
        firewall-cmd --reload && info "firewalld 已放行 179/tcp ✓" || true
    fi

    # ---- Step7: 验证 ----
    info "等待 BGP session 建立（约30秒）..."
    sleep 30

    echo ""
    echo -e "${B}── BGP Peer 状态 ──${N}"
    kubectl exec -n kube-system ds/cilium -- cilium bgp peers 2>/dev/null || \
        warn "稍后手动运行: kubectl exec -n kube-system ds/cilium -- cilium bgp peers"

    echo ""
    echo -e "${B}── LoadBalancer 服务 ──${N}"
    kubectl get svc -A --field-selector spec.type=LoadBalancer 2>/dev/null || true

    LB_IP=$(kubectl get svc -n kube-system hubble-ui \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    echo ""
    info "BGP + L2 配置完成 ✓"
    [[ -n "$LB_IP" ]] && echo -e "${B}Hubble UI: http://${LB_IP}:80${N}"
    echo ""
    echo -e "${Y}后期添加交换机 peer:${N}"
    echo "  kubectl edit ciliumbgpclusterconfig cilium-bgp"
    pause
}

# ----------------------------------------------------------------
do_longhorn_prereq() {
    title "⑨ Longhorn 前提依赖安装"

    echo -e "${B}将在所有节点安装以下依赖:${N}"
    echo "  - open-iscsi / iscsi-initiator-utils  (iSCSI，Longhorn 核心依赖)"
    echo "  - nfs-common / nfs-utils              (NFS 客户端，RWX + 备份)"
    echo "  - cryptsetup                           (加密卷支持)"
    echo "  - device-mapper                        (设备映射)"
    echo "  - 内核模块: iscsi_tcp / dm_crypt"
    echo ""
    read -rp "$(echo -e "${Y}确认执行? [y/N]: ${N}")" yn < ${TTY_INPUT}
    [[ "${yn,,}" != "y" ]] && { warn "已取消"; pause; return; }

    # ---- 自动检测包管理器 ----
    detect_pkgmgr() {
        if command -v apt-get &>/dev/null; then echo "apt"
        elif command -v dnf &>/dev/null;     then echo "dnf"
        elif command -v yum &>/dev/null;     then echo "yum"
        else echo "unknown"
        fi
    }

    PKG=$(detect_pkgmgr)
    info "本机包管理器: ${PKG}"
    [[ "$PKG" == "unknown" ]] && { err "不支持的包管理器，请手动安装"; pause; return; }

    # ---- 获取所有节点 IP ----
    if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null; then
        NODE_IPS=($(kubectl get nodes \
            -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'))
        info "检测到集群节点: ${NODE_IPS[*]}"
        REMOTE=true
    else
        warn "kubectl 不可用，仅在本机安装"
        REMOTE=false
    fi

    # ---- 本机安装 ----
    install_local() {
        local pkg=$1
        info "安装系统包 [${pkg}]..."
        case "$pkg" in
            apt)
                apt-get update -qq
                apt-get install -y open-iscsi nfs-common cryptsetup dmsetup
                ;;
            dnf)
                dnf install -y iscsi-initiator-utils nfs-utils cryptsetup device-mapper
                [[ ! -s /etc/iscsi/initiatorname.iscsi ]] && \
                    echo "InitiatorName=$(/sbin/iscsi-iname 2>/dev/null || echo iqn.$(date +%Y-%m).local:$(hostname))" \
                    > /etc/iscsi/initiatorname.iscsi
                ;;
            yum)
                yum install -y iscsi-initiator-utils nfs-utils cryptsetup device-mapper
                [[ ! -s /etc/iscsi/initiatorname.iscsi ]] && \
                    echo "InitiatorName=$(/sbin/iscsi-iname 2>/dev/null || echo iqn.$(date +%Y-%m).local:$(hostname))" \
                    > /etc/iscsi/initiatorname.iscsi
                ;;
        esac

        info "启动 iscsid..."
        systemctl enable iscsid && systemctl start iscsid
        systemctl is-active iscsid \
            && info "iscsid 运行正常 ✓" \
            || err  "iscsid 启动失败 ✗"

        info "加载内核模块..."
        modprobe iscsi_tcp && info "iscsi_tcp ✓" || warn "iscsi_tcp 加载失败"
        modprobe dm_crypt  && info "dm_crypt ✓"  || warn "dm_crypt 加载失败"

        printf 'iscsi_tcp\ndm_crypt\n' > /etc/modules-load.d/longhorn.conf
        info "内核模块持久化 ✓"
    }

    install_local "$PKG"

    # ---- 远程节点：DaemonSet（nsenter 进宿主机，脚本内自动识别发行版）----
    if [[ "$REMOTE" == "true" ]]; then
        info "通过 DaemonSet 在所有节点安装（自动识别发行版）..."

        # 生成 YAML 到临时文件，只展开 REGISTRY，其余 shell 变量转义
        LONGHORN_DS_YAML=$(mktemp /tmp/longhorn-ds-XXXXXX.yaml)

        # base64 编码安装脚本，避免 YAML 特殊字符冲突
        INSTALL_SCRIPT=$(base64 -w0 << 'SCRIPT'
set -e
NODE=$(cat /etc/hostname 2>/dev/null || hostname)
echo ">>> 节点: $NODE"
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y open-iscsi nfs-common cryptsetup dmsetup
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y iscsi-initiator-utils nfs-utils cryptsetup device-mapper
  [ -s /etc/iscsi/initiatorname.iscsi ] || echo "InitiatorName=$(/sbin/iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
elif command -v yum >/dev/null 2>&1; then
  yum install -y iscsi-initiator-utils nfs-utils cryptsetup device-mapper
  [ -s /etc/iscsi/initiatorname.iscsi ] || echo "InitiatorName=$(/sbin/iscsi-iname)" > /etc/iscsi/initiatorname.iscsi
else
  echo "ERROR: 不支持的包管理器"; exit 1
fi
systemctl enable iscsid 2>/dev/null || true
systemctl start  iscsid 2>/dev/null || true
modprobe iscsi_tcp 2>/dev/null || true
modprobe dm_crypt  2>/dev/null || true
echo -e "iscsi_tcp\ndm_crypt" > /etc/modules-load.d/longhorn.conf
echo ">>> $NODE 安装完成"
SCRIPT
)

        cat > "${LONGHORN_DS_YAML}" << YAML
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: longhorn-prereq-installer
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: longhorn-prereq
  template:
    metadata:
      labels:
        app: longhorn-prereq
    spec:
      hostPID: true
      hostNetwork: true
      tolerations:
      - operator: Exists
      initContainers:
      - name: installer
        image: ${REGISTRY}/library/busybox:1.36
        securityContext:
          privileged: true
        command:
        - sh
        - -c
        - nsenter --mount=/proc/1/ns/mnt --net=/proc/1/ns/net -- sh -c "echo ${INSTALL_SCRIPT} | base64 -d | sh"
      containers:
      - name: pause
        image: ${REGISTRY}/library/busybox:1.36
        command: ["sleep", "infinity"]
YAML
        kubectl apply -f "${LONGHORN_DS_YAML}"
        rm -f "${LONGHORN_DS_YAML}"

        info "等待所有节点完成（最多3分钟）..."
        kubectl rollout status daemonset/longhorn-prereq-installer \
            -n kube-system --timeout=180s || true

        info "清理 DaemonSet..."
        kubectl delete daemonset longhorn-prereq-installer \
            -n kube-system --ignore-not-found
    fi

    # ---- 最终验证 ----
    echo ""
    echo -e "${B}── 本机依赖验证 ──${N}"
    systemctl is-active iscsid &>/dev/null \
        && info "iscsid:     运行中 ✓" || err "iscsid:     未运行 ✗"
    lsmod | grep -q iscsi_tcp \
        && info "iscsi_tcp:  已加载 ✓" || warn "iscsi_tcp:  未加载"
    lsmod | grep -q dm_crypt \
        && info "dm_crypt:   已加载 ✓" || warn "dm_crypt:   未加载"
    { command -v mount.nfs4 &>/dev/null || command -v showmount &>/dev/null; } \
        && info "nfs-client: 已安装 ✓" || warn "nfs-client: 未安装"

    echo ""
    info "Longhorn 前提依赖安装完成 ✓"
    pause
}


# ----------------------------------------------------------------
do_longhorn() {
    title "⑩ 安装 Longhorn 分布式存储"
    need_kubectl || return
    need_helm    || return

    echo -e "${B}说明:${N}"
    echo "  - 分布式块存储，支持 PVC 自动创建"
    echo "  - 内置 Web UI 管理界面"
    echo "  - 支持快照、备份、多副本"
    echo "  - 请确保已执行选项 9（前提依赖安装）"
    echo ""

    # 检查前提依赖
    if ! systemctl is-active iscsid &>/dev/null; then
        warn "iscsid 未运行，建议先执行选项 9 安装前提依赖"
        read -rp "$(echo -e "${Y}是否继续? [y/N]: ${N}")" force < ${TTY_INPUT}
        [[ "${force,,}" != "y" ]] && { warn "已取消"; pause; return; }
    fi

    read -rp "$(echo -e "${Y}存储路径 [默认 /var/lib/longhorn]: ${N}")" DATA_PATH < ${TTY_INPUT}
    DATA_PATH="${DATA_PATH:-/var/lib/longhorn}"

    read -rp "$(echo -e "${Y}副本数 [默认 3]: ${N}")" REPLICA_COUNT < ${TTY_INPUT}
    REPLICA_COUNT="${REPLICA_COUNT:-3}"

    read -rp "$(echo -e "${Y}是否设为默认 StorageClass? [Y/n]: ${N}")" DEFAULT_SC < ${TTY_INPUT}
    DEFAULT_SC="${DEFAULT_SC:-y}"

    read -rp "$(echo -e "${Y}确认安装? [y/N]: ${N}")" yn < ${TTY_INPUT}
    [[ "${yn,,}" != "y" ]] && { warn "已取消"; pause; return; }

    info "添加 Longhorn helm repo..."
    helm repo add longhorn ${NEXUS_LONGHORN}/ 2>/dev/null || true
    helm repo update longhorn

    kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -

    # 生成 values 文件
    LONGHORN_VALUES="/tmp/longhorn-values.yaml"

    [[ "${DEFAULT_SC,,}" == "y" || "${DEFAULT_SC,,}" == "" ]] &&         IS_DEFAULT="true" || IS_DEFAULT="false"

    cat > "${LONGHORN_VALUES}" << VALEOF
defaultSettings:
  defaultDataPath: ${DATA_PATH}
  defaultReplicaCount: ${REPLICA_COUNT}
  nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod
  defaultDataLocality: best-effort

persistence:
  defaultClass: ${IS_DEFAULT}
  defaultClassReplicaCount: ${REPLICA_COUNT}

ingress:
  enabled: false

service:
  ui:
    type: LoadBalancer
VALEOF

    info "values 文件内容:"
    cat "${LONGHORN_VALUES}"
    echo ""

    info "安装 Longhorn..."
    helm upgrade --install longhorn longhorn/longhorn         --namespace longhorn-system         -f "${LONGHORN_VALUES}"

    info "等待 Longhorn 就绪（约2-3分钟）..."
    kubectl rollout status deployment/longhorn-ui         -n longhorn-system --timeout=300s || true

    echo ""
    echo -e "${B}── Longhorn Pod 状态 ──${N}"
    kubectl get pods -n longhorn-system
    echo ""
    echo -e "${B}── StorageClass ──${N}"
    kubectl get storageclass

    LB_IP=$(kubectl get svc -n longhorn-system longhorn-frontend         -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>/dev/null || echo "")
    echo ""
    info "Longhorn 安装完成 ✓"
    [[ -n "$LB_IP" ]] && echo -e "${B}Longhorn UI: http://${LB_IP}:80${N}" ||         echo -e "${Y}查看 UI 地址: kubectl get svc -n longhorn-system${N}"
    echo ""
    echo -e "${Y}使用示例（PVC）:${N}"
    cat << 'EXAMPLE'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-pvc
spec:
  storageClassName: longhorn
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EXAMPLE
    pause
}

# ----------------------------------------------------------------
do_ingress_nginx() {
    title "⑬ 安装 Ingress-Nginx（hostNetwork DaemonSet 模式）"
    need_kubectl || return
    need_helm    || return

    echo -e "${B}说明:${N}"
    echo "  - hostNetwork 模式，直接监听节点 80/443 端口"
    echo "  - DaemonSet 部署，每个选中节点都运行一个 Pod"
    echo "  - 无需 LoadBalancer，用节点 IP 直接访问"
    echo "  - 适合不需要 Cilium LB 的场景"
    echo ""

    # ---- 显示所有节点，让用户选择 ----
    echo -e "${B}当前集群节点:${N}"
    kubectl get nodes -o wide
    echo ""

    ALL_NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
    MASTER_NODES=($(kubectl get nodes \
        --selector='node-role.kubernetes.io/control-plane' \
        -o jsonpath='{.items[*].metadata.name}'))

    echo -e "${B}请选择部署 ingress-nginx 的节点（输入编号，多个用空格分隔）:${N}"
    echo -e "${Y}建议只选 Worker 节点${N}"
    echo ""
    for i in "${!ALL_NODES[@]}"; do
        NODE="${ALL_NODES[$i]}"
        IS_MASTER=""
        for m in "${MASTER_NODES[@]}"; do
            [[ "$m" == "$NODE" ]] && IS_MASTER=" ${R}[master]${N}" && break
        done
        echo -e "  $((i+1))) ${NODE}${IS_MASTER}"
    done
    echo ""
    read -rp "$(echo -e "${Y}请输入节点编号（如: 2 3 4）: ${N}")" NODE_CHOICES < ${TTY_INPUT}

    SELECTED_NODES=()
    for choice in $NODE_CHOICES; do
        idx=$((choice-1))
        if [[ $idx -ge 0 && $idx -lt ${#ALL_NODES[@]} ]]; then
            SELECTED_NODES+=("${ALL_NODES[$idx]}")
        else
            warn "无效编号: $choice，跳过"
        fi
    done

    if [[ ${#SELECTED_NODES[@]} -eq 0 ]]; then
        err "未选择任何节点，取消安装"
        pause; return
    fi

    echo ""
    echo -e "${B}已选择节点:${N}"
    for n in "${SELECTED_NODES[@]}"; do echo "  $n"; done
    echo ""

    read -rp "$(echo -e "${Y}worker-processes [默认 4]: ${N}")" WORKER_PROC < ${TTY_INPUT}
    WORKER_PROC="${WORKER_PROC:-4}"

    read -rp "$(echo -e "${Y}upstream-keepalive-connections [默认 500]: ${N}")" KEEPALIVE < ${TTY_INPUT}
    KEEPALIVE="${KEEPALIVE:-500}"

    read -rp "$(echo -e "${Y}确认安装? [y/N]: ${N}")" yn < ${TTY_INPUT}
    [[ "${yn,,}" != "y" ]] && { warn "已取消"; pause; return; }

    # ---- 打标签 ingress=nginx ----
    info "给选中节点打标签 ingress=nginx..."
    for node in "${SELECTED_NODES[@]}"; do
        kubectl label node "$node" ingress=nginx --overwrite
        info "  $node ← ingress=nginx ✓"
    done
    # 清除其他节点的标签
    for node in "${ALL_NODES[@]}"; do
        SKIP=false
        for s in "${SELECTED_NODES[@]}"; do
            [[ "$s" == "$node" ]] && SKIP=true && break
        done
        [[ "$SKIP" == "false" ]] && kubectl label node "$node" ingress- 2>/dev/null || true
    done

    info "添加 ingress-nginx helm repo..."
    helm repo add ingress-nginx ${NEXUS_INGRESS_NGINX}/ 2>/dev/null || true
    helm repo update ingress-nginx

    kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -

    NGINX_VALUES="/tmp/ingress-nginx-values.yaml"
    cat > "${NGINX_VALUES}" << VALEOF
controller:
  kind: DaemonSet
  replicaCount: 1
  hostNetwork: true
  dnsPolicy: ClusterFirstWithHostNet

  nodeSelector:
    ingress: nginx

  service:
    type: ClusterIP

  admissionWebhooks:
    enabled: false

  config:
    worker-processes: "${WORKER_PROC}"
    reuse-port: "true"
    upstream-keepalive-connections: "${KEEPALIVE}"
    disable-access-log: "true"
    worker-cpu-affinity: "auto"

  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
VALEOF

    info "values 文件内容:"
    cat "${NGINX_VALUES}"
    echo ""

    info "安装 ingress-nginx..."
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        -f "${NGINX_VALUES}"

    info "等待 ingress-nginx 就绪..."
    kubectl rollout status daemonset/ingress-nginx-controller \
        -n ingress-nginx --timeout=120s || true

    echo ""
    echo -e "${B}── ingress-nginx Pod 状态 ──${N}"
    kubectl get pods -n ingress-nginx -o wide
    echo ""

    # 显示节点 IP 访问方式
    echo -e "${B}── 访问地址（节点 IP 直接访问）──${N}"
    for node in "${SELECTED_NODES[@]}"; do
        NODE_IP=$(kubectl get node "$node" \
            -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
        echo "  http://${NODE_IP}:80"
    done

    echo ""
    info "ingress-nginx 安装完成 ✓"
    echo ""
    echo -e "${Y}使用示例（标准 Ingress）:${N}"
    cat << 'EXAMPLE'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    kubernetes.io/ingress.class: nginx
spec:
  rules:
  - host: app.wishfoxs.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-service
            port:
              number: 80
EXAMPLE
    pause
}

do_status() {
    title "查看集群状态"
    echo -e "${B}── Nodes ──${N}"
    kubectl get nodes -o wide 2>/dev/null || warn "kubectl 不可用"
    echo -e "\n${B}── kube-system Pods ──${N}"
    kubectl get pods -n kube-system 2>/dev/null || true
    pause
}

# ----------------------------------------------------------------

do_traefik() {
    title "⑪ 安装 Traefik Ingress Controller（生产多副本）"
    need_kubectl || return
    need_helm    || return

    echo -e "${B}说明:${N}"
    echo "  - 交互式选择调度节点，打 ingress=traefik 标签"
    echo "  - preferred 反亲和尽量分布在不同节点"
    echo "  - service.type=LoadBalancer，Cilium 自动分配 LB IP"
    echo "  - NET_BIND_SERVICE + sysctls 支持绑定 80/443"
    echo "  - Dashboard 默认关闭"
    echo ""

    # ---- 显示所有节点让用户选择 ----
    echo -e "${B}当前集群节点:${N}"
    kubectl get nodes -o wide
    echo ""

    ALL_NODES=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
    MASTER_NODES=($(kubectl get nodes \
        --selector='node-role.kubernetes.io/control-plane' \
        -o jsonpath='{.items[*].metadata.name}'))

    echo -e "${B}请选择 Traefik 可以调度的节点（输入编号，多个用空格分隔）:${N}"
    echo -e "${Y}建议只选 Worker 节点，不选 Master${N}"
    echo ""
    for i in "${!ALL_NODES[@]}"; do
        NODE="${ALL_NODES[$i]}"
        IS_MASTER=""
        for m in "${MASTER_NODES[@]}"; do
            [[ "$m" == "$NODE" ]] && IS_MASTER=" ${R}[master]${N}" && break
        done
        echo -e "  $((i+1))) ${NODE}${IS_MASTER}"
    done
    echo ""
    read -rp "$(echo -e "${Y}请输入节点编号（如: 2 3 4）: ${N}")" NODE_CHOICES < ${TTY_INPUT}

    SELECTED_NODES=()
    for choice in $NODE_CHOICES; do
        idx=$((choice-1))
        if [[ $idx -ge 0 && $idx -lt ${#ALL_NODES[@]} ]]; then
            SELECTED_NODES+=("${ALL_NODES[$idx]}")
        else
            warn "无效编号: $choice，跳过"
        fi
    done

    if [[ ${#SELECTED_NODES[@]} -eq 0 ]]; then
        err "未选择任何节点，取消安装"
        pause; return
    fi

    echo ""
    echo -e "${B}已选择节点:${N}"
    for n in "${SELECTED_NODES[@]}"; do echo "  $n"; done
    echo ""

    read -rp "$(echo -e "${Y}副本数 [默认 ${#SELECTED_NODES[@]}]: ${N}")" REPLICAS < ${TTY_INPUT}
    REPLICAS="${REPLICAS:-${#SELECTED_NODES[@]}}"

    read -rp "$(echo -e "${Y}HTTP 端口 [默认 80]: ${N}")" HTTP_PORT < ${TTY_INPUT}
    HTTP_PORT="${HTTP_PORT:-80}"

    read -rp "$(echo -e "${Y}HTTPS 端口 [默认 443]: ${N}")" HTTPS_PORT < ${TTY_INPUT}
    HTTPS_PORT="${HTTPS_PORT:-443}"

    read -rp "$(echo -e "${Y}是否开启 Dashboard? [y/N]: ${N}")" DASHBOARD < ${TTY_INPUT}
    DASHBOARD="${DASHBOARD:-n}"

    read -rp "$(echo -e "${Y}确认安装? [y/N]: ${N}")" yn < ${TTY_INPUT}
    [[ "${yn,,}" != "y" ]] && { warn "已取消"; pause; return; }

    # ---- 打标签 ingress=traefik ----
    info "给选中节点打标签 ingress=traefik..."
    for node in "${SELECTED_NODES[@]}"; do
        kubectl label node "$node" ingress=traefik --overwrite
        info "  $node ← ingress=traefik ✓"
    done

    # 清除其他节点的标签
    for node in "${ALL_NODES[@]}"; do
        SKIP=false
        for s in "${SELECTED_NODES[@]}"; do
            [[ "$s" == "$node" ]] && SKIP=true && break
        done
        [[ "$SKIP" == "false" ]] && kubectl label node "$node" ingress- 2>/dev/null || true
    done

    info "添加 Traefik helm repo..."
    helm repo add traefik ${NEXUS_HELM}/helm.traefik/ 2>/dev/null || true
    helm repo update traefik

    kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -

    TRAEFIK_VALUES="/tmp/traefik-values.yaml"

    if [[ "${DASHBOARD,,}" == "y" ]]; then
        DASHBOARD_SECTION="ingressRoute:
  dashboard:
    enabled: true"
    else
        DASHBOARD_SECTION="ingressRoute:
  dashboard:
    enabled: false"
    fi

    cat > "${TRAEFIK_VALUES}" << VALEOF
deployment:
  replicas: ${REPLICAS}

service:
  type: LoadBalancer

ports:
  web:
    port: ${HTTP_PORT}
  websecure:
    port: ${HTTPS_PORT}

securityContext:
  capabilities:
    drop:
    - ALL
    add:
    - NET_BIND_SERVICE
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 65532

podSecurityContext:
  sysctls:
  - name: net.ipv4.ip_unprivileged_port_start
    value: "80"

nodeSelector:
  ingress: traefik

ingressClass:
  enabled: true
  isDefaultClass: true

providers:
  kubernetesIngress:
    enabled: true
    publishedService:
      enabled: true

${DASHBOARD_SECTION}

affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchLabels:
            app.kubernetes.io/name: traefik
        topologyKey: kubernetes.io/hostname

logs:
  general:
    level: INFO
  access:
    enabled: true
VALEOF

    info "values 文件内容:"
    cat "${TRAEFIK_VALUES}"
    echo ""

    info "安装 Traefik（${REPLICAS} 副本）..."
    helm upgrade --install traefik traefik/traefik \
        --namespace traefik \
        -f "${TRAEFIK_VALUES}"

    info "等待 Traefik 就绪..."
    kubectl rollout status deployment/traefik -n traefik --timeout=120s || true

    echo ""
    echo -e "${B}── Traefik Pod 状态 ──${N}"
    kubectl get pods -n traefik -o wide
    echo ""
    echo -e "${B}── Traefik Service ──${N}"
    kubectl get svc -n traefik

    LB_IP=$(kubectl get svc -n traefik traefik \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    echo ""
    info "Traefik 安装完成 ✓"
    [[ -n "$LB_IP" ]] && echo -e "${B}Traefik 入口 IP: ${LB_IP}${N}"

    # ---- 测试 Ingress ----
    echo ""
    read -rp "$(echo -e "${Y}是否部署 whoami 测试验证 Ingress 路由? [y/N]: ${N}")" do_test_ingress < ${TTY_INPUT}
    if [[ "${do_test_ingress,,}" == "y" ]]; then
        info "部署 whoami 测试服务..."
        kubectl create deployment whoami \
            --image=traefik/whoami \
            --namespace default \
            --dry-run=client -o yaml | kubectl apply -f -
        kubectl expose deployment whoami \
            --port=80 --namespace default \
            --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true
        kubectl apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami-test
  namespace: default
spec:
  ingressClassName: traefik
  rules:
  - host: whoami.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: whoami
            port:
              number: 80
YAML
        info "等待 whoami Pod 就绪..."
        kubectl rollout status deployment/whoami -n default --timeout=60s || true
        sleep 3
        RESULT=$(curl -s -H "Host: whoami.local" "http://${LB_IP}" --connect-timeout 5 || echo "连接失败")
        echo ""
        echo -e "${B}── 测试结果 ──${N}"
        if echo "$RESULT" | grep -q "Hostname"; then
            info "Ingress 路由测试通过 ✓"
            echo "$RESULT" | grep -E "Hostname|IP:|X-Forwarded"
        else
            warn "测试失败，响应: ${RESULT}"
            warn "手动测试: curl -H 'Host: whoami.local' http://${LB_IP}"
        fi
        echo ""
        read -rp "$(echo -e "${Y}是否清理测试资源? [Y/n]: ${N}")" clean_test < ${TTY_INPUT}
        clean_test="${clean_test:-y}"
        if [[ "${clean_test,,}" == "y" ]]; then
            kubectl delete ingress whoami-test -n default --ignore-not-found
            kubectl delete svc whoami -n default --ignore-not-found
            kubectl delete deployment whoami -n default --ignore-not-found
            info "测试资源已清理 ✓"
        else
            warn "手动清理: kubectl delete deploy,svc,ingress whoami whoami-test -n default"
        fi
    fi

    echo ""
    echo -e "${Y}Ingress 使用示例:${N}"
    cat << 'EXAMPLE'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
spec:
  ingressClassName: traefik
  rules:
  - host: app.wishfoxs.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-service
            port:
              number: 80
EXAMPLE
    pause
}

# ================================================================
#  主菜单
# ================================================================
while true; do
    clear
    echo -e "${C}${B}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║   K8s 集群安装菜单  (sxxpqp 运智运维)   ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${N}"
    echo "  1) 内核参数优化          (k8skerneloptimize.sh)"
    echo "  2) 安装 Kubernetes       (installk8s.sh)"
    echo "  3) 安装 Helm             (install-helm.sh)"
    echo "  4) 配置镜像加速源        (统一代理 ${REGISTRY})"
    echo "  5) 安装 Cilium CNI       (eBPF + Hubble UI)"
    echo "  6) 安装 Rancher          (多集群管理平台)"
    echo "  7) Cilium 网络连通性验证 (测试Pod互通/DNS/跨节点)"
    echo "  8) 配置 Cilium BGP       (节点间路由 + LoadBalancer IP)"
    echo "  9) Longhorn 前提依赖安装 (iscsi/nfs/内核模块)"
    echo " 10) 安装 Longhorn         (分布式存储)"
    echo " 11) 安装 Traefik          (生产多副本 Ingress Controller)"
    echo " 12) 安装 Ingress-Nginx    (hostNetwork DaemonSet 模式)"
    echo " 13) 查看集群状态"
    echo "  0) 退出"
    echo ""
    read -rp "$(echo -e "${Y}请选择 [0-13]: ${N}")" choice < ${TTY_INPUT}

    case "$choice" in
        1)  do_kernel          ;;
        2)  do_k8s             ;;
        3)  do_helm            ;;
        4)  do_mirror          ;;
        5)  do_cilium          ;;
        6)  do_rancher         ;;
        7)  do_test            ;;
        8)  do_bgp             ;;
        9)  do_longhorn_prereq ;;
        10) do_longhorn        ;;
        11) do_traefik         ;;
        12) do_ingress_nginx   ;;
        13) do_status          ;;
        0)  echo -e "${G}Bye!${N}"; exit 0 ;;
        *)  warn "无效选项"; sleep 1 ;;
    esac
done