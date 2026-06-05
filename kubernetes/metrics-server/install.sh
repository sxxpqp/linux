#!/usr/bin/env bash
# 系统: Kubernetes (K8s 1.25+, 1.28 已验证) — metrics-server v0.7.2
# 上游: https://github.com/kubernetes-sigs/metrics-server/releases/tag/v0.7.2
#
# 走代理:
#   - YAML  → nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent(raw 直连不通)
#   - 镜像  → 保持上游 registry.k8s.io/metrics-server/metrics-server:v0.7.2,
#             由节点 containerd mirror 透明转发(/etc/containerd/certs.d/registry.k8s.io/hosts.toml)
#
# 默认:apply 之前给 metrics-server 的 args 加 --kubelet-insecure-tls(kubeadm 自签 kubelet 证书必需),
#       已经加过的会自动跳过(幂等)。云厂商托管集群(EKS/AKS/GKE)有这个 flag 不影响,留着也行。
#
# k3s 自带 metrics-server,本脚本检测到 k3s 直接 exit。

set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

MS_VERSION="v0.7.2"
NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"
NAMESPACE="kube-system"

DRY_RUN="false"
NO_INSECURE_TLS="false"

usage() {
  cat <<'EOF'
用法: bash install.sh [选项]

可选:
  --no-insecure-tls       不给 args 加 --kubelet-insecure-tls
                          (云厂商托管 / 自己签了 kubelet 证书的集群用这个)
  --dry-run               只下 YAML 改好 args,不 apply,副本留在 ./metrics-server-yaml-dryrun
  -h, --help              显示帮助

环境变量:
  NEXUS_RAW               Nexus raw 代理前缀
  MS_VERSION              metrics-server tag(默认 v0.7.2,1.28 验证过)

示例:
  bash install.sh                  # kubeadm 默认装法
  bash install.sh --no-insecure-tls   # 云厂商托管集群
  bash install.sh --dry-run        # 看 YAML 改成什么样
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-insecure-tls) NO_INSECURE_TLS="true" ;;
    --dry-run) DRY_RUN="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }

# ============================================================
# 1/5 前置检查
# ============================================================
log "[1/5] 前置检查"

command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
ok "kubectl 可用"

# 集群版本(用 /version API,比 `kubectl version -o json` 稳)
K8S_VER=$(kubectl get --raw /version 2>/dev/null | grep -o '"gitVersion":"[^"]*' | cut -d'"' -f4 || true)
if [ -n "$K8S_VER" ]; then
  K8S_MINOR=$(echo "$K8S_VER" | sed -E 's/^v?([0-9]+)\.([0-9]+).*/\2/')
  if [ "$K8S_MINOR" -lt 19 ] 2>/dev/null; then
    err "集群版本 $K8S_VER 低于 1.19,metrics-server v0.7.2 不支持"; exit 1
  fi
  ok "集群版本: $K8S_VER (metrics-server v0.7.2 支持 1.19+,1.28 已验证)"
else
  warn "无法读取集群版本,跳过版本检查"
fi

# k3s 检测(k3s 自带 metrics-server)
if kubectl -n ${NAMESPACE} get deploy metrics-server -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q 'k3s'; then
  err "检测到 k3s 自带 metrics-server,无需重装"; exit 1
fi
if [ -d /var/lib/rancher/k3s ] 2>/dev/null; then
  warn "本机看到 /var/lib/rancher/k3s(k3s 节点?)— k3s 默认带 metrics-server,确认是否需要重装"
fi

# 已装幂等提示
EXISTING=""
if kubectl -n ${NAMESPACE} get deploy metrics-server >/dev/null 2>&1; then
  EXISTING=$(kubectl -n ${NAMESPACE} get deploy metrics-server -o jsonpath='{.spec.template.spec.containers[0].image}')
  warn "metrics-server 已装(image=$EXISTING),脚本走 apply 幂等覆盖"
fi

# Terminating 检测
if kubectl -n ${NAMESPACE} get deploy metrics-server -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
  err "deploy/metrics-server 正在 Terminating,先等清干净再装"; exit 1
fi

# ============================================================
# 2/5 下载 YAML
# ============================================================
log "[2/5] 下载 components.yaml(走 Nexus 代理)"

WORK_DIR=$(mktemp -d /tmp/metrics-server-install.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT
ok "工作目录: $WORK_DIR"

URL="${NEXUS_RAW}/kubernetes-sigs/metrics-server/${MS_VERSION}/manifests/release/components.yaml"
if curl -fsSLk "$URL" -o "${WORK_DIR}/components.yaml"; then
  ok "components.yaml ($(wc -l < "${WORK_DIR}/components.yaml") 行)"
else
  err "下载失败: $URL"; exit 1
fi

# ============================================================
# 3/5 改 args(加 --kubelet-insecure-tls)+ 检查 image
# ============================================================
log "[3/5] 改 args + 验证 image"

if [ "$NO_INSECURE_TLS" = "true" ]; then
  ok "--no-insecure-tls 已指定,args 不动"
else
  # 已经有了就跳过,否则在 --metric-resolution 后面加一行
  if grep -q -- '--kubelet-insecure-tls' "${WORK_DIR}/components.yaml"; then
    ok "components.yaml 已含 --kubelet-insecure-tls(上游变了?),跳过追加"
  else
    sed -i.bak '/- --metric-resolution=15s/a\        - --kubelet-insecure-tls' "${WORK_DIR}/components.yaml"
    rm "${WORK_DIR}/components.yaml.bak"
    if grep -q -- '--kubelet-insecure-tls' "${WORK_DIR}/components.yaml"; then
      ok "已加 - --kubelet-insecure-tls(kubeadm 自签 kubelet 证书必需)"
    else
      err "插入 --kubelet-insecure-tls 失败:components.yaml 里没找到锚点 '- --metric-resolution=15s'"
      err "上游可能改了 args 结构,手动检查 ${WORK_DIR}/components.yaml"; exit 1
    fi
  fi
fi

# 验证 image(保持上游,走节点 containerd mirror)
IMG=$(grep -E '^\s*image:' "${WORK_DIR}/components.yaml" | head -1 | awk '{print $2}')
ok "image: $IMG (保持上游,走节点 containerd mirror)"

# ============================================================
# 4/5 dry-run 在这里截止
# ============================================================
if [ "$DRY_RUN" = "true" ]; then
  warn "DRY-RUN: YAML 已下载到 ${WORK_DIR},未 apply"
  cp -r "${WORK_DIR}" "./metrics-server-yaml-dryrun"
  ok "副本已留在: ./metrics-server-yaml-dryrun"
  trap - EXIT
  exit 0
fi

# ============================================================
# 5/5 apply + 等 ready + 验证
# ============================================================
log "[4/5] 应用 components.yaml"
kubectl apply -f "${WORK_DIR}/components.yaml"
ok "已 apply"

log "[5/5] 等 deployment ready + 验证 metrics API"
kubectl -n ${NAMESPACE} rollout status deploy/metrics-server --timeout=180s

# APIService 可用(.status.conditions[?(@.type=="Available")].status == "True")
log "       等 metrics.k8s.io APIService 可用"
for i in $(seq 1 30); do
  if kubectl get apiservice v1beta1.metrics.k8s.io \
       -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q True; then
    ok "v1beta1.metrics.k8s.io Available"
    break
  fi
  [ "$i" = "30" ] && { err "等 30s 仍未 Available,看 deploy/metrics-server 日志"; exit 1; }
  sleep 1
done

ok "metrics-server 安装完成"
echo
log "验证(应该出节点 / Pod 的 CPU MEM):"
kubectl top node 2>/dev/null || warn "kubectl top node 失败,可能要再等 30s(采集第一轮)"
echo
kubectl top pod -A 2>/dev/null | head -10 || true
echo
log "下一步:bash kubernetes/vpa/install.sh(VPA recommender 现在能算出建议了)"
