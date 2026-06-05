#!/usr/bin/env bash
# 系统: Kubernetes (K8s 1.28 已验证) — VPA (Vertical Pod Autoscaler) v1.0.0
# 上游: https://github.com/kubernetes/autoscaler/tree/vpa-release-1.0/vertical-pod-autoscaler
#
# 默认装 Recommender 模式:CRD + RBAC + recommender + updater
#   - 只给资源建议值(kubectl describe vpa <name> 看 recommendation)
#   - 不会真改 Pod requests/limits,也不会注入 admission
# 加 --with-admission 才装 Auto 模式的 admission-controller
#   - 需要 TLS 证书,本脚本会调上游 hack/admission-controller-gencerts.sh 生成
#
# 走代理:
#   - YAML  → nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent(raw 直连不通)
#   - 镜像  → 保持上游 registry.k8s.io/autoscaling/vpa-*:1.0.0,由节点 containerd
#             mirror(/etc/containerd/certs.d/registry.k8s.io/hosts.toml)透明转发
#             → 装 VPA 前先确认 4 份 hosts.toml 装好,见 kubernetes/containerd/

set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

VPA_BRANCH="vpa-release-1.0"
NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"
NAMESPACE="kube-system"

WITH_ADMISSION="false"
DRY_RUN="false"

usage() {
  cat <<'EOF'
用法: bash install.sh [选项]

可选:
  --with-admission        同时装 admission-controller(Auto 模式),会生成 TLS secret
  --dry-run               只下载 YAML 改好镜像,不 apply
  -h, --help              显示帮助

环境变量(改默认值用):
  NEXUS_RAW               Nexus raw 代理前缀(YAML 走它,默认 nexus.ihome.sxxpqp.top:8443)

示例:
  bash install.sh                       # Recommender 模式(推荐先用这个观察)
  bash install.sh --with-admission      # Auto 模式(VPA 会注入 Pod requests)
  bash install.sh --dry-run             # 看下 YAML 改成什么样
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --with-admission) WITH_ADMISSION="true" ;;
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
ok "kubectl: $(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion":"v[^"]*' | head -1 | cut -d'"' -f4)"

# 用 /version API 比 `kubectl version -o json` 解析稳(后者不同 kubectl 版本字段顺序 / 格式有变)
K8S_VER=$(kubectl get --raw /version 2>/dev/null | grep -o '"gitVersion":"[^"]*' | cut -d'"' -f4 || true)
if [ -n "$K8S_VER" ]; then
  K8S_MINOR=$(echo "$K8S_VER" | sed -E 's/^v?([0-9]+)\.([0-9]+).*/\2/')
  if [ "$K8S_MINOR" -lt 25 ] 2>/dev/null; then
    err "集群版本 $K8S_VER 低于 1.25,VPA v1.0.0 不支持"; exit 1
  fi
  ok "集群版本: $K8S_VER (VPA v1.0.0 支持 1.25+,1.28 已验证)"
else
  warn "无法读取集群版本(kubectl get --raw /version 失败),跳过版本检查"
fi

# metrics-server(recommender 默认数据源)
if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
  ok "metrics-server 已装"
else
  warn "metrics-server 未装,recommender 默认会读它,建议先装(否则 recommendation 一直 nil)"
fi

# Terminating 残留 / CRD 已存在(幂等性提示)
if kubectl get crd verticalpodautoscalers.autoscaling.k8s.io >/dev/null 2>&1; then
  warn "VPA CRD 已存在,脚本将走 apply 幂等"
fi
for d in vpa-recommender vpa-updater vpa-admission-controller; do
  if kubectl -n ${NAMESPACE} get deploy $d -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
    err "deploy/$d 正在 Terminating,先 bash uninstall.sh --apply 清干净再装"; exit 1
  fi
done

# ============================================================
# 2/5 下载 YAML
# ============================================================
log "[2/5] 下载 YAML(走 Nexus 代理)"

WORK_DIR=$(mktemp -d /tmp/vpa-install.XXXXXX)
trap "rm -rf $WORK_DIR" EXIT
ok "工作目录: $WORK_DIR"

BASE="${NEXUS_RAW}/kubernetes/autoscaler/${VPA_BRANCH}/vertical-pod-autoscaler/deploy"
FILES=(vpa-v1-crd-gen.yaml vpa-rbac.yaml recommender-deployment.yaml updater-deployment.yaml)
[ "$WITH_ADMISSION" = "true" ] && FILES+=(admission-controller-deployment.yaml)

for f in "${FILES[@]}"; do
  if curl -fsSLk "${BASE}/${f}" -o "${WORK_DIR}/${f}"; then
    ok "$f ($(wc -l < "${WORK_DIR}/${f}") 行)"
  else
    err "下载失败: ${BASE}/${f}"; exit 1
  fi
done

# ============================================================
# 3/5 检查镜像 registry(只检测、不改写 — containerd mirror 透明转发)
# ============================================================
log "[3/5] 检查节点 containerd registry.k8s.io mirror 是否配好"

# image 字段保持 registry.k8s.io/autoscaling/vpa-*,要求节点 containerd
# /etc/containerd/certs.d/registry.k8s.io/hosts.toml 已经指向 k8s.ihome.sxxpqp.top:8443
# 在本机(脚本运行机)只能提示,真正生效在每个节点上
for f in recommender-deployment.yaml updater-deployment.yaml admission-controller-deployment.yaml; do
  [ -f "${WORK_DIR}/${f}" ] || continue
  img=$(grep -E '^\s*image:' "${WORK_DIR}/${f}" | head -1 | awk '{print $2}')
  ok "$f → $img (镜像保持上游,走节点 containerd mirror)"
done
warn "镜像由节点 containerd 转发,若 Pod ImagePullBackOff:节点上没配 mirror"
warn "  → 在节点上跑: bash docker/containerd/mirrors.sh && systemctl restart containerd"
warn "  → 验证: ctr -n k8s.io image pull registry.k8s.io/autoscaling/vpa-recommender:1.0.0"

# ============================================================
# 4/5 dry-run 在这里截止
# ============================================================
if [ "$DRY_RUN" = "true" ]; then
  warn "DRY-RUN: YAML 已下载到 ${WORK_DIR},未 apply"
  warn "去掉 --dry-run 真跑;或 cp -r ${WORK_DIR} ./vpa-yaml 留底"
  cp -r "${WORK_DIR}" "./vpa-yaml-dryrun"
  ok "副本已留在: ./vpa-yaml-dryrun"
  trap - EXIT
  exit 0
fi

# ============================================================
# 5/5 apply CRD + RBAC + deployments
# ============================================================
log "[4/5] 应用 CRD + RBAC"
kubectl apply -f "${WORK_DIR}/vpa-v1-crd-gen.yaml"
kubectl apply -f "${WORK_DIR}/vpa-rbac.yaml"
ok "CRD + RBAC 已 apply"

# CRD 要先 Established 再 apply 用它的资源(虽然这里 deployments 不依赖 CRD,但建议)
kubectl wait --for=condition=Established crd/verticalpodautoscalers.autoscaling.k8s.io --timeout=60s >/dev/null
kubectl wait --for=condition=Established crd/verticalpodautoscalercheckpoints.autoscaling.k8s.io --timeout=60s >/dev/null
ok "CRD established"

log "[5/5] 应用 recommender + updater"
kubectl apply -f "${WORK_DIR}/recommender-deployment.yaml"
kubectl apply -f "${WORK_DIR}/updater-deployment.yaml"

if [ "$WITH_ADMISSION" = "true" ]; then
  log "      生成 admission-controller TLS 证书"
  # 上游 hack/admission-controller-gencerts.sh 生成 4 个 secret:
  #   vpa-tls-certs(给 admission-controller 用)
  # 这里 inline 一份精简版,本地用 openssl 自签即可
  CERT_DIR="${WORK_DIR}/certs"
  mkdir -p "$CERT_DIR"
  pushd "$CERT_DIR" >/dev/null

  openssl genrsa -out ca.key 2048 >/dev/null 2>&1
  openssl req -x509 -new -nodes -key ca.key -days 3650 -out ca.crt -subj "/CN=vpa-webhook-ca" >/dev/null 2>&1

  cat > server.conf <<EOF
[req]
distinguished_name = req
[v3_req]
subjectAltName = @alt_names
[alt_names]
DNS.1 = vpa-webhook
DNS.2 = vpa-webhook.${NAMESPACE}
DNS.3 = vpa-webhook.${NAMESPACE}.svc
EOF
  openssl genrsa -out server.key 2048 >/dev/null 2>&1
  openssl req -new -key server.key -out server.csr \
    -subj "/CN=vpa-webhook.${NAMESPACE}.svc" \
    -config server.conf >/dev/null 2>&1
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 3650 -extensions v3_req -extfile server.conf >/dev/null 2>&1

  kubectl -n ${NAMESPACE} create secret generic vpa-tls-certs \
    --from-file=caCert.pem=ca.crt \
    --from-file=serverCert.pem=server.crt \
    --from-file=serverKey.pem=server.key \
    --dry-run=client -o yaml | kubectl apply -f -
  ok "vpa-tls-certs secret 已创建"
  popd >/dev/null

  kubectl apply -f "${WORK_DIR}/admission-controller-deployment.yaml"
fi

# ============================================================
# 等 ready + 验证
# ============================================================
log "[5/5] 等组件 ready"
kubectl -n ${NAMESPACE} rollout status deploy/vpa-recommender --timeout=180s
kubectl -n ${NAMESPACE} rollout status deploy/vpa-updater --timeout=180s
if [ "$WITH_ADMISSION" = "true" ]; then
  kubectl -n ${NAMESPACE} rollout status deploy/vpa-admission-controller --timeout=180s
fi

ok "VPA 安装完成"
echo
log "组件状态:"
kubectl -n ${NAMESPACE} get deploy -l 'app in (vpa-recommender,vpa-updater,vpa-admission-controller)' \
  -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,AVAIL:.status.availableReplicas 2>/dev/null \
  || kubectl -n ${NAMESPACE} get deploy | grep -E '^vpa-'

echo
log "快速验证(创建一个 VPA 对象观察 recommendation):"
cat <<'EOF'
  cat <<YAML | kubectl apply -f -
  apiVersion: autoscaling.k8s.io/v1
  kind: VerticalPodAutoscaler
  metadata:
    name: demo-vpa
    namespace: default
  spec:
    targetRef:
      apiVersion: apps/v1
      kind: Deployment
      name: <你的 deploy 名>
    updatePolicy:
      updateMode: "Off"    # 只给建议不改 Pod
  YAML

  # 等 1-2 分钟后看建议值
  kubectl describe vpa demo-vpa -n default | grep -A 10 'Recommendation'
EOF
