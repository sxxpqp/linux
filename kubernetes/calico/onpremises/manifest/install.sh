#!/usr/bin/env bash
# 系统: Kubernetes (K8s) + Linux 内核 5.3+(开 eBPF 时必需,iptables 模式不限)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/onpremises/manifest/install.sh
# 用法: curl -sL <URL> -o install.sh && bash install.sh [选项]
#
# 用单 calico.yaml(非 operator)方式在已运行集群安装 Calico,可选切 eBPF + 删 kube-proxy。
#
# 跟 operator 方式相比:
#   + 单文件,改 image / env 直接 sed,排障简单
#   + 不需要 operator 控制循环,资源占用少 1 个 deploy
#   - 升级麻烦(operator 一键 patch CR,manifest 要重新 apply 整个 yaml)
#   - eBPF 切换是 2-step(改 ConfigMap + patch FelixConfiguration),不像 operator 一行 CR
#
# 参考文档:
#   https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises
#   https://docs.tigera.io/calico/latest/operations/ebpf/enabling-ebpf

set -euo pipefail

# ============================================================
# 默认值 / 参数解析
# ============================================================
CALICO_VERSION="v3.28.2"
POD_CIDR=""    # 默认空,自动从 kubeadm-config 探测;探测失败 fallback 192.168.0.0/16
APISERVER_HOST=""
APISERVER_PORT="6443"
ENABLE_EBPF="false"
DELETE_KUBE_PROXY="false"

usage() {
  cat <<'EOF'
用法: bash install.sh [选项]

可选:
  --apiserver-host=HOST    API server 地址(开 eBPF + 删 kube-proxy 时必填)
  --apiserver-port=PORT    API server 端口,默认 6443
  --pod-cidr=CIDR          Pod CIDR,默认自动探测 kubeadm-config.podSubnet,探测失败 fallback 192.168.0.0/16
  --calico-version=VER     Calico 版本,默认 v3.28.2
  --enable-ebpf            装完后切到 eBPF dataplane
  --delete-kube-proxy      删 kube-proxy(必须同时开 --enable-ebpf)
  -h, --help               显示帮助

示例:
  # 经典 iptables 模式,kube-proxy 保留(最稳)
  bash install.sh

  # eBPF 模式,删 kube-proxy(性能模式)
  bash install.sh --apiserver-host=192.168.1.100 --enable-ebpf --delete-kube-proxy
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apiserver-host=*) APISERVER_HOST="${1#*=}" ;;
    --apiserver-port=*) APISERVER_PORT="${1#*=}" ;;
    --pod-cidr=*) POD_CIDR="${1#*=}" ;;
    --calico-version=*) CALICO_VERSION="${1#*=}" ;;
    --enable-ebpf) ENABLE_EBPF="true" ;;
    --delete-kube-proxy) DELETE_KUBE_PROXY="true" ;;
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
# 1/6 前置检查
# ============================================================
log "[1/6] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
ok "kubectl 可用"

if [ "$ENABLE_EBPF" = "true" ]; then
  KERNEL=$(uname -r)
  KMAJ=$(echo "$KERNEL" | awk -F. '{print $1}')
  KMIN=$(echo "$KERNEL" | awk -F. '{print $2}')
  if [ "$KMAJ" -lt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -lt 3 ]; }; then
    err "eBPF 要求内核 5.3+,当前 $KERNEL"
    exit 1
  fi
  ok "内核 $KERNEL 满足 eBPF 要求"
fi

if [ "$DELETE_KUBE_PROXY" = "true" ] && [ "$ENABLE_EBPF" != "true" ]; then
  err "--delete-kube-proxy 必须配合 --enable-ebpf 使用,否则集群 Service 网络会崩"
  exit 1
fi

if [ "$ENABLE_EBPF" = "true" ] && [ -z "$APISERVER_HOST" ]; then
  APISERVER_HOST=$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  if [ -z "$APISERVER_HOST" ]; then
    err "开 eBPF 必须指定 --apiserver-host"
    exit 1
  fi
  warn "自动探测到 API server: $APISERVER_HOST(HA 集群请显式指定 LB)"
fi

if kubectl get ds -n kube-system 2>/dev/null | grep -E 'cilium|kube-flannel|weave' >/dev/null; then
  err "检测到其他 CNI"
  exit 1
fi

# Pod CIDR(manifest 模式 operator 不校验,但 IPPool 跟 kubeadm 不一致 Pod 也拿不到 IP)
if [ -z "$POD_CIDR" ]; then
  POD_CIDR=$(kubectl -n kube-system get cm kubeadm-config -o yaml 2>/dev/null \
    | grep -oE 'podSubnet: [0-9./,]+' | awk '{print $2}' | head -1 || true)
  if [ -n "$POD_CIDR" ]; then
    ok "自动探测 Pod CIDR: $POD_CIDR (kubeadm-config.podSubnet)"
  else
    POD_CIDR="192.168.0.0/16"
    warn "未从 kubeadm-config 探测到 podSubnet,回退默认 $POD_CIDR"
  fi
else
  ok "Pod CIDR: $POD_CIDR(用户指定)"
fi

ok "前置检查通过"

# ============================================================
# 2/6 下载 calico.yaml
# ============================================================
log "[2/6] 下载 calico.yaml (${CALICO_VERSION})"

# yaml 下载源走 Nexus raw 代理(GitHub raw 直连基本不通,见 CLAUDE.md "已知踩坑 #1")
# 上游原始路径:https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml
NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"
CALICO_URL="${NEXUS_RAW}/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
TMP_YAML=$(mktemp /tmp/calico.XXXXXX.yaml)
trap "rm -f $TMP_YAML" EXIT

if ! curl -fsSLk "$CALICO_URL" -o "$TMP_YAML"; then
  err "下载失败: $CALICO_URL"
  err "  - 检查 Nexus 是否可达: curl -kI $NEXUS_RAW/"
  err "  - 或外网环境直连: NEXUS_RAW=https://raw.githubusercontent.com bash install.sh ..."
  exit 1
fi
ok "已下载到 $TMP_YAML ($(wc -l < "$TMP_YAML") 行)"

# ============================================================
# 3/6 改 Pod CIDR(如果非默认)
# ============================================================
log "[3/6] 调整 Pod CIDR"

if [ "$POD_CIDR" != "192.168.0.0/16" ]; then
  # 官方 calico.yaml 里 CALICO_IPV4POOL_CIDR 被注释掉了,需要取消注释 + 改值
  sed -i \
    -e 's|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|' \
    -e "s|#   value: \"192.168.0.0/16\"|  value: \"${POD_CIDR}\"|" \
    "$TMP_YAML"
  ok "CIDR 改为 $POD_CIDR"
else
  ok "保持默认 192.168.0.0/16"
fi

# ============================================================
# 4/6 apply calico.yaml
# ============================================================

# kubernetes-services-endpoint ConfigMap 必须在 calico.yaml apply 之 前 建好,
# 否则 install-cni init container 无法通过 ClusterIP 访问 API server(尤其 kube-proxy 已挂时)。
# 即使默认 iptables 模式也建,无害且防止 kube-proxy 意外缺失时安装失败。
if [ -z "$APISERVER_HOST" ]; then
  APISERVER_HOST=$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  [ -z "$APISERVER_HOST" ] && warn "无法自动探测 API server 地址,跳过 ConfigMap"
fi
if [ -n "$APISERVER_HOST" ] && ! kubectl -n kube-system get cm kubernetes-services-endpoint >/dev/null 2>&1; then
  log "  写 kubernetes-services-endpoint ConfigMap(install-cni 需要)"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubernetes-services-endpoint
  namespace: kube-system
data:
  KUBERNETES_SERVICE_HOST: "${APISERVER_HOST}"
  KUBERNETES_SERVICE_PORT: "${APISERVER_PORT}"
EOF
  ok "ConfigMap 已写"
fi

log "[4/6] apply Calico"

kubectl apply -f "$TMP_YAML"
ok "calico.yaml 已 apply"

log "  等 calico-node DaemonSet ready..."
kubectl -n kube-system rollout status ds/calico-node --timeout=300s
ok "calico-node ready"

log "  等 calico-kube-controllers..."
kubectl -n kube-system rollout status deploy/calico-kube-controllers --timeout=180s
ok "calico-kube-controllers ready"

# 不开 eBPF 到这里就结束
if [ "$ENABLE_EBPF" != "true" ]; then
  log "==== 安装完成 (iptables/VXLAN 模式) ===="
  kubectl -n kube-system get pods -l k8s-app=calico-node
  exit 0
fi

# ============================================================
# 5/6 切 eBPF dataplane
# ============================================================
log "[5/6] 切换到 eBPF dataplane"

# 5.1 kubernetes-services-endpoint ConfigMap(如果前面已建就跳过)
if kubectl -n kube-system get cm kubernetes-services-endpoint >/dev/null 2>&1; then
  ok "kubernetes-services-endpoint ConfigMap 已存在(跳过)"
else
  log "  写 kubernetes-services-endpoint ConfigMap"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubernetes-services-endpoint
  namespace: kube-system
data:
  KUBERNETES_SERVICE_HOST: "${APISERVER_HOST}"
  KUBERNETES_SERVICE_PORT: "${APISERVER_PORT}"
EOF
  ok "ConfigMap 已写"
fi

# 5.2 重启 calico-node + typha 让它读到新 ConfigMap
log "  重启 calico-node 读新 ConfigMap"
kubectl -n kube-system rollout restart ds/calico-node
kubectl -n kube-system rollout status ds/calico-node --timeout=300s
ok "calico-node 已重启"

# 5.3 创建/更新 FelixConfiguration 开 BPF
# manifest 模式用 crd.projectcalico.org/v1,operator 用 projectcalico.org/v3
log "  FelixConfiguration: bpfEnabled=true"
if ! kubectl get felixconfiguration default >/dev/null 2>&1; then
  kubectl apply -f - <<EOF
apiVersion: crd.projectcalico.org/v1
kind: FelixConfiguration
metadata:
  name: default
spec:
  bpfEnabled: true
  bpfConnectTimeLoadBalancing: TCP
EOF
else
  kubectl patch felixconfiguration default --type=merge -p '{"spec":{"bpfEnabled":true,"bpfConnectTimeLoadBalancing":"TCP"}}'
fi
ok "FelixConfiguration.bpfEnabled = true"

# 5.4 等 BPF 起来
log "  等 BPF 程序加载到所有 node(约 30s)"
sleep 30
NODE_POD=$(kubectl -n kube-system get pod -l k8s-app=calico-node -o name | head -1)
if kubectl -n kube-system logs "$NODE_POD" --tail=200 2>/dev/null | grep -q "BPF"; then
  ok "calico-node 日志已含 BPF 字样"
else
  warn "未在日志看到 BPF,手动检查 kubectl -n kube-system logs $NODE_POD | grep -i bpf"
fi

# ============================================================
# 6/6 删 kube-proxy
# ============================================================
log "[6/6] 处理 kube-proxy"

if [ "$DELETE_KUBE_PROXY" != "true" ]; then
  warn "未指定 --delete-kube-proxy,kube-proxy 仍在跑(eBPF 与 kube-proxy 共存浪费 CPU,但不会冲突)"
  cat <<EOF

下一步建议(手动执行):
  1. 验证业务正常(curl ClusterIP / NodePort 都通)
  2. 删 kube-proxy:
       kubectl -n kube-system delete ds kube-proxy
       kubectl -n kube-system delete cm kube-proxy
  3. 节点残留 KUBE-* iptables 链处理:
       - 推荐:逐个节点重启(最干净,清空 conntrack / iptables 一次到位)
       - 不重启也行:kube-proxy 已删,KUBE-* 链不会再被更新,留着无害
       ⚠ 不要跑 'iptables-save | grep -v KUBE | iptables-restore'(易误伤其它规则)
EOF
  log "==== 安装完成 (eBPF + kube-proxy 共存) ===="
  exit 0
fi

warn "即将删除 kube-proxy DaemonSet,5 秒后开始(Ctrl-C 中止)..."
sleep 5

kubectl -n kube-system delete ds kube-proxy --ignore-not-found
kubectl -n kube-system delete cm kube-proxy --ignore-not-found
ok "kube-proxy 已删除"

# 通知 Calico 接管 service NAT(删了 kube-proxy 必须做,否则 ClusterIP/DNS 全挂)
log "  通知 Calico 接管 service NAT..."
kubectl patch felixconfiguration default --type=merge \
  -p '{"spec":{"bpfKubeProxyIptablesCleanupEnabled":true,"bpfKubeProxyMinSyncPeriod":"5s"}}' 2>/dev/null || \
  warn "FelixConfiguration patch 失败,可能 default 不存在,跳过"
log "  滚动重启 calico-node 以加载 kube-proxy replacement..."
kubectl -n kube-system rollout restart ds/calico-node >/dev/null 2>&1 || true
kubectl -n kube-system rollout status ds/calico-node --timeout=120s
ok "calico-node 已重启,service NAT 已接管"

warn "节点上的 iptables KUBE-* 链需要手动清理(每个 node):"
echo "  iptables-save | grep -v KUBE | iptables-restore"
echo "  ipvs 用户额外: ipvsadm -C"

log "==== 安装完成 (eBPF + 无 kube-proxy) ===="
kubectl -n kube-system get pods -l k8s-app=calico-node
echo
echo "状态查询:"
echo "  kubectl get felixconfiguration default -o yaml | grep -i bpf"
echo "  kubectl -n kube-system get pods -l k8s-app=calico-node"
