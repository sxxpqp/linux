#!/usr/bin/env bash
# 系统: Kubernetes (K8s) + Linux 内核 5.3+(eBPF 必需)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/onpremises/operator/install.sh
# 用法: curl -sL <URL> -o install.sh && bash install.sh --apiserver-host=<HOST> [选项]
#
# 在已运行的 K8s 集群上用 Tigera Operator 安装 Calico,可选启用 eBPF dataplane 并替换 kube-proxy。
#
# 参考文档:
#   https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises
#   https://docs.tigera.io/calico/latest/operations/ebpf/enabling-ebpf
#
# 关键顺序(不能反过来,否则 Calico 自己会失联):
#   1. 配 kubernetes-services-endpoint ConfigMap
#   2. 装 tigera-operator + Installation CR(已是 BPF dataplane)
#   3. 等 Calico ready
#   4. 删 kube-proxy(可选,加 --delete-kube-proxy)
#   5. 验证 BPF dataplane 真在跑

set -euo pipefail

# ============================================================
# 默认值 / 参数解析
# ============================================================
CALICO_VERSION="v3.28.2"
POD_CIDR=""    # 默认空,自动从 kubeadm-config 探测;探测失败 fallback 192.168.0.0/16
APISERVER_HOST=""
APISERVER_PORT="6443"
DELETE_KUBE_PROXY="false"
SKIP_ENDPOINT_CM="false"
INSTALLATION_YAML=""    # 不传则用同目录的 installation.yaml,失败则从 GitHub 拉

usage() {
  cat <<'EOF'
用法: bash install.sh --apiserver-host=<HOST> [选项]

必填:
  --apiserver-host=HOST    API server 地址(HA 集群填 LB / VIP,单 master 填节点 IP)

可选:
  --apiserver-port=PORT    API server 端口,默认 6443
  --pod-cidr=CIDR          Pod CIDR,默认自动探测 kubeadm-config.podSubnet,探测失败 fallback 192.168.0.0/16
                           ⚠ operator 模式严格校验 cidr ⊆ kubeadm podSubnet,不匹配 calico-system 不会建
  --calico-version=VER     Calico 版本,默认 v3.28.2
  --installation-yaml=PATH 自定义 Installation CR 路径(否则用脚本同目录的)
  --delete-kube-proxy      安装完成后删除 kube-proxy(危险,需手动确认)
  --skip-endpoint-cm       跳过 kubernetes-services-endpoint ConfigMap(已有时)
  -h, --help               显示帮助

示例:
  # 单 master 自动探测 + 不删 kube-proxy(最安全,先验证)
  bash install.sh --apiserver-host=192.168.1.10

  # HA 集群,装完直接替换 kube-proxy
  bash install.sh --apiserver-host=192.168.1.100 --delete-kube-proxy
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apiserver-host=*) APISERVER_HOST="${1#*=}" ;;
    --apiserver-port=*) APISERVER_PORT="${1#*=}" ;;
    --pod-cidr=*) POD_CIDR="${1#*=}" ;;
    --calico-version=*) CALICO_VERSION="${1#*=}" ;;
    --installation-yaml=*) INSTALLATION_YAML="${1#*=}" ;;
    --delete-kube-proxy) DELETE_KUBE_PROXY="true" ;;
    --skip-endpoint-cm) SKIP_ENDPOINT_CM="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

# 防 systemctl 进 pager(脚本里不一定会调,但养成习惯)
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

# ============================================================
# 1/7 前置检查
# ============================================================
log "[1/7] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
ok "kubectl 可用"

# 内核 5.3+
KERNEL=$(uname -r)
KMAJ=$(echo "$KERNEL" | awk -F. '{print $1}')
KMIN=$(echo "$KERNEL" | awk -F. '{print $2}')
if [ "$KMAJ" -lt 5 ] || { [ "$KMAJ" -eq 5 ] && [ "$KMIN" -lt 3 ]; }; then
  err "eBPF 要求 Linux 内核 5.3+,当前 $KERNEL,请先升级内核或改用 manifest/ 方式(iptables 模式)"
  exit 1
fi
ok "内核 $KERNEL 满足 eBPF 要求"

# bpffs 挂载
if ! mount | grep -q 'bpf on /sys/fs/bpf'; then
  warn "/sys/fs/bpf 未挂载 bpffs,Calico 启动时会自动 mount,但建议在 fstab 固化"
fi

# Pod CIDR(关键!operator 模式会校验 IPPool.cidr 必须 ⊆ kubeadm.podSubnet,不匹配直接拒绝 reconcile)
if [ -z "$POD_CIDR" ]; then
  POD_CIDR=$(kubectl -n kube-system get cm kubeadm-config -o yaml 2>/dev/null \
    | grep -oE 'podSubnet: [0-9./,]+' | awk '{print $2}' | head -1 || true)
  if [ -n "$POD_CIDR" ]; then
    ok "自动探测 Pod CIDR: $POD_CIDR (kubeadm-config.podSubnet)"
  else
    POD_CIDR="192.168.0.0/16"
    warn "未从 kubeadm-config 探测到 podSubnet,回退默认 $POD_CIDR"
    warn "如果 kubeadm init 时用了别的 CIDR,operator 会拒绝 reconcile!请显式 --pod-cidr=<CIDR>"
  fi
else
  ok "Pod CIDR: $POD_CIDR(用户指定)"
fi

# API server 地址
if [ -z "$APISERVER_HOST" ]; then
  APISERVER_HOST=$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
  if [ -z "$APISERVER_HOST" ]; then
    err "未指定 --apiserver-host 且自动探测失败"
    exit 1
  fi
  warn "自动探测到 API server: $APISERVER_HOST"
  warn "HA 集群请显式 --apiserver-host=<LB IP>,否则单 master 故障后 Calico 失联"
fi
ok "API server: ${APISERVER_HOST}:${APISERVER_PORT}"

# 检查冲突 CNI
if kubectl get ds -n kube-system 2>/dev/null | grep -E 'cilium|kube-flannel|weave' >/dev/null; then
  err "检测到其他 CNI(cilium/flannel/weave),请先卸载"
  kubectl get ds -n kube-system | grep -E 'cilium|kube-flannel|weave' >&2
  exit 1
fi

# 检查残留 Terminating 状态(上次 uninstall 没清干净就重装会踩这个坑)
# 在 Terminating 资源上做 apply → kubectl 会变成 "configured" 而不是 "created",
# operator 拿到 zombie 状态,RBAC 不会被正常重建,calico-kube-controllers 会 RBAC forbidden
TERMINATING_FOUND=false
for cr in installation apiserver; do
  if kubectl get $cr default -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
    err "$cr/default 正在 Terminating,无法在此状态下重装"
    err "  → kubectl patch $cr default --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    err "  → kubectl delete $cr default --ignore-not-found"
    TERMINATING_FOUND=true
  fi
done
for ns in calico-system tigera-operator calico-apiserver; do
  if kubectl get ns $ns -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; then
    err "namespace $ns 正在 Terminating,无法在此状态下重装"
    err "  → 剥 finalizer:"
    err "    kubectl get ns $ns -o json | \\"
    err "      python3 -c \"import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))\" | \\"
    err "      kubectl replace --raw \"/api/v1/namespaces/$ns/finalize\" -f -"
    TERMINATING_FOUND=true
  fi
done
if [ "$TERMINATING_FOUND" = "true" ]; then
  err ""
  err "建议:先跑 uninstall.sh --apply 彻底清干净再重装"
  exit 1
fi

# 检查残留 ClusterRole(operator 不会强覆盖已存在的 ClusterRole)
# 命中说明上次 manifest 或 operator 没清干净 RBAC,operator 重装时不会重建,
# 新启 Pod 会用着不完整的旧 RBAC 报 forbidden
STALE_RBAC=""
for role in calico-kube-controllers calico-node calico-cni-plugin; do
  if kubectl get clusterrole $role >/dev/null 2>&1 && \
     ! kubectl get ns tigera-operator >/dev/null 2>&1; then
    STALE_RBAC="$STALE_RBAC $role"
  fi
done
if [ -n "$STALE_RBAC" ]; then
  warn "检测到残留 ClusterRole(tigera-operator ns 不存在但 RBAC 还在):$STALE_RBAC"
  warn "  operator 不会强覆盖已存在的 ClusterRole,继续装会触发 RBAC forbidden"
  warn "  建议先清:kubectl delete clusterrole$STALE_RBAC"
  warn "          kubectl delete clusterrolebinding$STALE_RBAC"
  warn "  10 秒后继续(Ctrl-C 中止)..."
  sleep 10
fi

# 检查残留 webhook(backend service 死了之后会拦 admission,导致后续 API 调用诡异失败)
STALE_WH=$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null | grep -iE 'calico|tigera|operator' || true)
if [ -n "$STALE_WH" ]; then
  err "检测到残留 webhook(backend 已死会拦后续 API 调用,kubectl 显示成功但实际失败):"
  echo "$STALE_WH" | sed 's/^/    - /' >&2
  err "建议先清:"
  echo "    kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | \\" >&2
  echo "      grep -iE 'calico|tigera|operator' | xargs -r kubectl delete" >&2
  exit 1
fi

# 检查是否已装 Calico
if kubectl get ns tigera-operator >/dev/null 2>&1; then
  warn "tigera-operator namespace 已存在,脚本将走 apply(幂等),不会破坏现有部署"
fi

# 检查 kube-system 里有没有老 Calico(manifest 方式装的)
if kubectl -n kube-system get ds calico-node >/dev/null 2>&1; then
  warn "检测到 kube-system 里有老 Calico(manifest 方式装的),与 operator 模式可能冲突"
  warn "  → 老 calico-node DaemonSet: kubectl -n kube-system get ds calico-node"
  warn "  → 建议:"
  warn "    A. 想保留老 Calico:取消安装,改用 manifest/install.sh --enable-ebpf 在原地切 BPF"
  warn "    B. 想切 operator:先 kubectl -n kube-system delete -f calico.yaml,等 10 秒,再重跑本脚本"
  warn "  10 秒后继续,Ctrl-C 中止..."
  sleep 10
fi

ok "前置检查通过"

# ============================================================
# 2/7 配 kubernetes-services-endpoint ConfigMap(关键!)
# 不配的话删了 kube-proxy 后 Calico 自己连不上 API server
# ============================================================
log "[2/7] 配置 kubernetes-services-endpoint ConfigMap"

if [ "$SKIP_ENDPOINT_CM" = "true" ]; then
  warn "--skip-endpoint-cm 跳过"
else
  # tigera-operator namespace 还没建,先建它
  kubectl create ns tigera-operator --dry-run=client -o yaml | kubectl apply -f -

  kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubernetes-services-endpoint
  namespace: tigera-operator
data:
  KUBERNETES_SERVICE_HOST: "${APISERVER_HOST}"
  KUBERNETES_SERVICE_PORT: "${APISERVER_PORT}"
EOF
  ok "ConfigMap kubernetes-services-endpoint 已 apply"
fi

# ============================================================
# 3/7 安装 tigera-operator
# ============================================================
log "[3/7] 安装 tigera-operator (${CALICO_VERSION})"

# yaml 下载源走 Nexus raw 代理(GitHub raw 直连基本不通,见 CLAUDE.md "已知踩坑 #1")
# 上游原始路径:https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml
NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"
TIGERA_OP_URL="${NEXUS_RAW}/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml"
log "  拉取 $TIGERA_OP_URL"
TMP_OP=$(mktemp /tmp/tigera-operator.XXXXXX.yaml)
trap "rm -f $TMP_OP" EXIT

if ! curl -fsSLk "$TIGERA_OP_URL" -o "$TMP_OP"; then
  err "下载 tigera-operator.yaml 失败"
  err "  - 检查 Nexus 是否可达: curl -kI $NEXUS_RAW/"
  err "  - 或外网环境直连: NEXUS_RAW=https://raw.githubusercontent.com bash install.sh ..."
  err "  - 或换版本: --calico-version=v3.28.x"
  exit 1
fi

kubectl apply --server-side -f "$TMP_OP"
ok "tigera-operator manifest 已 apply"

log "  等待 tigera-operator deployment ready..."
kubectl -n tigera-operator rollout status deploy/tigera-operator --timeout=180s
ok "tigera-operator 运行中"

# ============================================================
# 4/7 apply Installation CR(包含 BPF dataplane 配置)
# ============================================================
log "[4/7] apply Installation CR (BPF dataplane)"

if [ -z "$INSTALLATION_YAML" ]; then
  # 默认用脚本同目录的
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "$SCRIPT_DIR/installation.yaml" ]; then
    INSTALLATION_YAML="$SCRIPT_DIR/installation.yaml"
  fi
fi

if [ -n "$INSTALLATION_YAML" ] && [ -f "$INSTALLATION_YAML" ]; then
  log "  使用 $INSTALLATION_YAML(替换占位符 REPLACE_POD_CIDR → $POD_CIDR)"
  # 模板里 cidr 是占位符 REPLACE_POD_CIDR,避免用户裸 apply 时踩 CIDR 不匹配
  if ! grep -q "REPLACE_POD_CIDR" "$INSTALLATION_YAML"; then
    warn "$INSTALLATION_YAML 不含 REPLACE_POD_CIDR 占位符,可能是旧版或自定义文件,跳过 sed 直接 apply"
    kubectl apply -f "$INSTALLATION_YAML"
  else
    sed "s|REPLACE_POD_CIDR|${POD_CIDR}|g" "$INSTALLATION_YAML" | kubectl apply -f -
  fi
else
  log "  使用内嵌默认配置"
  kubectl apply -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    linuxDataplane: BPF
    bgp: Disabled
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: ${POD_CIDR}
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
  controlPlaneReplicas: 2
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
fi
ok "Installation CR 已 apply"

# ============================================================
# 5/7 等 Calico 全部 ready
# ============================================================
log "[5/7] 等待 Calico Pods ready"

# 失败时 dump 诊断信息,避免用户瞎猜
dump_calico_diag() {
  echo
  err "==== 诊断信息 ===="
  echo "--- tigera-operator 日志(最后 60 行) ---"
  kubectl -n tigera-operator logs deploy/tigera-operator --tail=60 2>&1 || true
  echo
  echo "--- Installation CR status ---"
  kubectl get installation default -o yaml 2>&1 | tail -40 || true
  echo
  echo "--- tigerastatus ---"
  kubectl get tigerastatus 2>&1 || true
  echo
  echo "--- 相关 namespace ---"
  kubectl get ns 2>&1 | grep -iE 'calico|tigera' || true
  echo
  echo "--- calico-system Pod 状态(如果 ns 存在) ---"
  kubectl -n calico-system get pods 2>&1 || true
  echo
  err "==================="
}

# operator 会自动建 calico-system namespace,但要拉镜像 + reconcile,慢的话 3-5 分钟
log "  等待 calico-system namespace 出现(最多 5 分钟)..."
NS_READY=false
for i in $(seq 1 60); do
  if kubectl get ns calico-system >/dev/null 2>&1; then
    NS_READY=true
    ok "calico-system namespace 已出现(第 $((i*5)) 秒)"
    break
  fi
  sleep 5
  if [ $((i % 6)) -eq 0 ]; then
    # 每 30 秒打一次进度,顺便给个 hint
    log "  ...仍在等(已等 $((i*5)) 秒),operator 可能在拉镜像,Ctrl-C 后跑 kubectl -n tigera-operator logs deploy/tigera-operator --tail=50 看"
  fi
done

if [ "$NS_READY" != "true" ]; then
  err "calico-system namespace 5 分钟内未出现"
  dump_calico_diag
  cat <<'EOF'

【常见原因 + 对应修法】

1. operator 日志显示 ImagePullBackOff / Failed to pull image
   → quay.io 拉不动,改走 Harbor 代理:
     kubectl patch installation default --type=merge \
       -p '{"spec":{"registry":"quay.ihome.sxxpqp.top:8443/"}}'

2. operator 日志显示 "unknown field" / "strict decoding error"
   → Installation CR 字段跟你的 Calico 版本不匹配
   → 看 installation.yaml 里 spec 下哪个字段不对,删掉

3. tigerastatus 显示 message="kubernetes-services-endpoint ConfigMap not found"
   → ConfigMap 没建对或在错的 namespace
     kubectl -n tigera-operator get cm kubernetes-services-endpoint -o yaml

4. operator 日志正常但一直 reconcile
   → 网络拉镜像太慢,加大耐心等(可能 10 分钟+),或改 image 源

EOF
  exit 1
fi

# 等所有 calico-node ready
log "  等 calico-node DaemonSet rollout(最多 8 分钟,首次拉镜像慢)..."
if ! kubectl -n calico-system rollout status ds/calico-node --timeout=480s; then
  err "calico-node DaemonSet 没起来"
  dump_calico_diag
  exit 1
fi
ok "calico-node ready"

log "  等 calico-kube-controllers..."
if ! kubectl -n calico-system rollout status deploy/calico-kube-controllers --timeout=300s; then
  err "calico-kube-controllers 没起来"
  dump_calico_diag
  exit 1
fi
ok "calico-kube-controllers ready"

# ============================================================
# 6/7 验证 BPF dataplane 真的在跑
# operator 模式的权威源是 Installation.spec.calicoNetwork.linuxDataplane,
# 不是 FelixConfiguration.bpfEnabled(operator 不一定显式同步到 Felix CR)
# 实际是否在跑用 `calico-node -bpf conntrack dump` 验证
# ============================================================
log "[6/7] 验证 eBPF dataplane"

DATAPLANE=$(kubectl get installation default -o jsonpath='{.spec.calicoNetwork.linuxDataplane}' 2>/dev/null)
if [ "$DATAPLANE" = "BPF" ]; then
  ok "Installation.spec.calicoNetwork.linuxDataplane = BPF"
else
  warn "Installation 没设 BPF dataplane,linuxDataplane=$DATAPLANE"
fi

# 实测 BPF dataplane:conntrack dump 能输出数据就说明 BPF map 已 attach
NODE_POD=$(kubectl -n calico-system get pod -l k8s-app=calico-node -o name | head -1)
if [ -n "$NODE_POD" ]; then
  if kubectl -n calico-system exec "$NODE_POD" -- calico-node -bpf conntrack dump 2>/dev/null | head -3 | grep -qE '^(TCP|UDP|ICMP)'; then
    ok "BPF conntrack dump 有数据 → BPF dataplane 真的在跑"
  else
    warn "BPF conntrack dump 没数据(可能还没流量,也可能 BPF 没起来)"
    warn "  手动验证:kubectl -n calico-system exec $NODE_POD -- calico-node -bpf conntrack dump | head"
  fi
fi

# ============================================================
# 7/7 service NAT 接管 + 可选删 kube-proxy
# Installation CR 已经是 linuxDataplane: BPF,无论 kube-proxy 在不在都要接管 service NAT
# ============================================================
log "[7/7] service NAT 接管 + kube-proxy"

# ---------- 7a. 通知 Calico 接管 service NAT(必做,跟 kube-proxy 无关) ----------
# BPF dataplane 下 operator 不一定自动设这个字段,脚本显式 patch + restart
log "  通知 Calico 接管 service NAT..."
kubectl patch felixconfiguration default --type=merge \
  -p '{"spec":{"bpfKubeProxyIptablesCleanupEnabled":true,"bpfKubeProxyMinSyncPeriod":"5s"}}' \
  >/dev/null 2>&1 || warn "FelixConfiguration default 尚不存在,稍后重试"
ok "FelixConfiguration.bpfKubeProxyIptablesCleanupEnabled = true"

log "  滚动重启 calico-node 以加载 kube-proxy replacement..."
kubectl -n calico-system rollout restart ds/calico-node >/dev/null 2>&1 || true
kubectl -n calico-system rollout status ds/calico-node --timeout=120s
ok "calico-node 已重启,service NAT 已接管"

# ---------- 7b. 处理 kube-proxy ----------
if [ "$DELETE_KUBE_PROXY" = "true" ]; then
  if kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
    kubectl -n kube-system delete ds kube-proxy --ignore-not-found
    kubectl -n kube-system delete cm kube-proxy --ignore-not-found
    ok "kube-proxy 已删除"
  else
    ok "kube-proxy 不存在,跳过删除"
  fi
else
  warn "未指定 --delete-kube-proxy,kube-proxy 仍在跑(BPF 共存,但推荐删它减少跳转)"
fi

log "==== 安装完成 ===="
kubectl -n calico-system get pods
echo
echo "状态查询:"
echo "  kubectl get installation default -o yaml"
echo "  kubectl get felixconfiguration default -o yaml"
echo "  kubectl -n calico-system get pods"
