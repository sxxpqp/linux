#!/usr/bin/env bash
# 系统: Kubernetes (K8s) — 安装 sig-storage-local-static-provisioner(Local PV 静态发现)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/local-static-provisioner/install.sh
# 用法: curl -sL <URL> -o install.sh && bash install.sh [选项]
#
# 说明:
#   - 本脚本只负责 K8s 侧部署,不负责节点磁盘分区 / mkfs / mount / /etc/fstab
#   - 盘规划建议:一块盘/分区一个挂载点,例如 /mnt/disks/ssd1、/mnt/disks/ssd2
#   - 多块同类 SSD 继续共用同一个 StorageClass,默认 local-ssd
#   - 后续新增磁盘时,继续新增 /mnt/disks/<disk>,K8s 侧通常无需改脚本参数
#   - 生产默认回收策略: Retain(删 PVC 不自动删数据,需人工回收)
#   - 节点标签默认: local-storage=ssd

set -euo pipefail

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

NAMESPACE="local-storage"
RELEASE_NAME="provisioner"
STORAGE_CLASS_NAME="local-ssd"
RECLAIM_POLICY="Retain"
NODE_LABEL_KEY="local-storage"
NODE_LABEL_VALUE="ssd"
HOST_DIR="/mnt/disks"
MOUNT_DIR="/mnt/disks"
FS_TYPE="ext4"
HELM_REPO_NAME="local-static-provisioner"
HELM_REPO_URL="https://nexus.ihome.sxxpqp.top:8443/repository/helm-sig-storage/"
HELM_CHART="local-static-provisioner/local-static-provisioner"
CHART_VERSION="2.9.0"
WAIT_TIMEOUT="300s"
DRY_RUN="false"

usage() {
  cat <<'EOF'
用法: bash install.sh [选项]

默认安装:
  1) 检查 kubectl / helm / 本地文件
  2) 校验至少 1 个节点带 local-storage=ssd 标签
  3) 创建 local-ssd StorageClass(默认 reclaimPolicy=Retain)
  4) 通过 Nexus Helm 仓库安装 sig-storage-local-static-provisioner
  5) 等待 DaemonSet ready 并输出验证命令

选项:
  --namespace=NAME                  Namespace,默认 local-storage
  --release=NAME                    Helm release 名,默认 provisioner
  --storage-class=NAME              StorageClass 名,默认 local-ssd
  --reclaim-policy=Retain|Delete    PV 回收策略,默认 Retain(生产推荐)
  --node-label=K=V                  仅调度到带此标签的节点,默认 local-storage=ssd
  --host-dir=PATH                   节点本地卷根目录,默认 /mnt/disks
  --mount-dir=PATH                  容器内挂载目录,默认 /mnt/disks
  --fs-type=TYPE                    文件系统类型,默认 ext4
  --chart-version=VER               chart 版本,默认 2.9.0
  --repo-url=URL                    Helm 仓库地址,默认走 Nexus
  --wait-timeout=300s               等待 DaemonSet ready 超时,默认 300s
  --dry-run                         只打印计划,不执行
  -h, --help                        显示帮助

生产建议:
  - 一块盘/分区一个挂载点,例如 /mnt/disks/ssd1、/mnt/disks/ssd2
  - 多块同类 SSD 共用一个 StorageClass;Pod 副本分散靠 workload 自己的 anti-affinity / topology spread
  - 默认 reclaimPolicy=Retain,删 PVC 不等于删数据

示例:
  bash install.sh
  bash install.sh --dry-run
  bash install.sh --storage-class=local-ssd --reclaim-policy=Retain
  bash install.sh --node-label=local-storage=ssd --host-dir=/mnt/disks --mount-dir=/mnt/disks
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --namespace=*) NAMESPACE="${1#*=}" ;;
    --release=*) RELEASE_NAME="${1#*=}" ;;
    --storage-class=*) STORAGE_CLASS_NAME="${1#*=}" ;;
    --reclaim-policy=*) RECLAIM_POLICY="${1#*=}" ;;
    --node-label=*)
      LABEL_PAIR="${1#*=}"
      if ! printf '%s' "$LABEL_PAIR" | grep -q '='; then
        echo "ERROR: --node-label 需要 K=V 格式,例如 local-storage=ssd" >&2
        exit 1
      fi
      NODE_LABEL_KEY="${LABEL_PAIR%%=*}"
      NODE_LABEL_VALUE="${LABEL_PAIR#*=}"
      ;;
    --host-dir=*) HOST_DIR="${1#*=}" ;;
    --mount-dir=*) MOUNT_DIR="${1#*=}" ;;
    --fs-type=*) FS_TYPE="${1#*=}" ;;
    --chart-version=*) CHART_VERSION="${1#*=}" ;;
    --repo-url=*) HELM_REPO_URL="${1#*=}" ;;
    --wait-timeout=*) WAIT_TIMEOUT="${1#*=}" ;;
    --dry-run) DRY_RUN="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: 未知参数: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

case "$RECLAIM_POLICY" in
  Retain|Delete) ;;
  *)
    err_msg="ERROR: --reclaim-policy 只支持 Retain 或 Delete"
    echo "$err_msg" >&2
    exit 1
    ;;
esac

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*" >&2; }
run() {
  if [ "$DRY_RUN" = "true" ]; then
    echo -e "  ${YELLOW}[dry-run]${NC} $*"
  else
    echo -e "  ${GREEN}\$${NC} $*"
    eval "$@"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"
SC_TEMPLATE="${SCRIPT_DIR}/storageclass-local-ssd.yaml"
TEST_YAML="${SCRIPT_DIR}/pvc-pod-test.yaml"
TMP_SC=""
trap 'rm -f "$TMP_SC"' EXIT

log "[1/5] 前置检查"
command -v kubectl >/dev/null || { err "kubectl 不存在"; exit 1; }
command -v helm >/dev/null || { err "helm 不存在"; exit 1; }
ok "kubectl / helm 可用"

[ -f "$VALUES_FILE" ] || { err "values.yaml 不存在: $VALUES_FILE"; exit 1; }
[ -f "$SC_TEMPLATE" ] || { err "storageclass-local-ssd.yaml 不存在: $SC_TEMPLATE"; exit 1; }
[ -f "$TEST_YAML" ] || { err "pvc-pod-test.yaml 不存在: $TEST_YAML"; exit 1; }
ok "脚本同目录文件齐全"

MATCHED_NODES=$(kubectl get nodes -l "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" -o name 2>/dev/null || true)
if [ -z "$MATCHED_NODES" ]; then
  warn "没有节点带 ${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} 标签"
  warn "  → 先打标签: kubectl label node <NAME> ${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} --overwrite"
  if [ "$DRY_RUN" != "true" ]; then
    err "没有目标节点,中止安装"
    exit 1
  fi
else
  COUNT=$(printf '%s\n' "$MATCHED_NODES" | sed '/^$/d' | wc -l | tr -d ' ')
  ok "检测到 ${COUNT} 个节点带 ${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}:"
  kubectl get nodes -l "${NODE_LABEL_KEY}=${NODE_LABEL_VALUE}" \
    -o custom-columns='NAME:.metadata.name,IP:.status.addresses[?(@.type=="InternalIP")].address' --no-headers 2>/dev/null | sed 's/^/    /'
fi

warn "本脚本不负责节点磁盘分区/mkfs/挂载,请确认每个目标节点已准备好本地挂载点"
warn "生产建议:一块盘/分区一个挂载点,例如 ${HOST_DIR}/ssd1、${HOST_DIR}/ssd2"
warn "多块同类 SSD 可继续共用 StorageClass ${STORAGE_CLASS_NAME};副本分散靠 workload 自己的 anti-affinity / topology spread"
if [ "$RECLAIM_POLICY" = "Retain" ]; then
  warn "当前 reclaimPolicy=${RECLAIM_POLICY}: 删除 PVC 不会自动删除本地数据,后续需人工回收"
else
  warn "当前 reclaimPolicy=${RECLAIM_POLICY}: 更适合测试/临时数据,生产默认更推荐 Retain"
fi
[ "$DRY_RUN" = "true" ] && warn "DRY-RUN 模式,只打印不执行"

log "[2/5] 创建 namespace + StorageClass"
run "kubectl create ns ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -"

TMP_SC=$(mktemp)
cp "$SC_TEMPLATE" "$TMP_SC"
sed -i "s|^  name: .*|  name: ${STORAGE_CLASS_NAME}|" "$TMP_SC"
sed -i "s|^reclaimPolicy: .*|reclaimPolicy: ${RECLAIM_POLICY}|" "$TMP_SC"
run "kubectl apply -f ${TMP_SC}"
ok "StorageClass 模板已准备: ${STORAGE_CLASS_NAME} (reclaimPolicy=${RECLAIM_POLICY})"

log "[3/5] 通过 Nexus Helm 仓库安装 provisioner"
run "helm repo add ${HELM_REPO_NAME} ${HELM_REPO_URL} --force-update"
run "helm repo update ${HELM_REPO_NAME} >/dev/null"
run "helm upgrade --install ${RELEASE_NAME} ${HELM_CHART} --namespace ${NAMESPACE} --version ${CHART_VERSION} -f ${VALUES_FILE} --set classes[0].name=${STORAGE_CLASS_NAME} --set classes[0].hostDir=${HOST_DIR} --set classes[0].mountDir=${MOUNT_DIR} --set classes[0].fsType=${FS_TYPE} --set nodeSelector.${NODE_LABEL_KEY}=${NODE_LABEL_VALUE} --wait --timeout ${WAIT_TIMEOUT}"
ok "Helm release 已提交: ${RELEASE_NAME}"

log "[4/5] 等待 DaemonSet ready"
if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] 跳过等待"
else
  kubectl -n "$NAMESPACE" rollout status ds/${RELEASE_NAME}-local-volume-provisioner --timeout="$WAIT_TIMEOUT"
  ok "DaemonSet ready"
fi

log "[5/5] 验证"
if [ "$DRY_RUN" = "true" ]; then
  warn "[dry-run] 跳过在线验证"
else
  kubectl -n "$NAMESPACE" get pods -o wide || true
  kubectl get sc "$STORAGE_CLASS_NAME" || true
  kubectl get pv || true
fi

echo
log "==== 安装完成 ===="
echo "常用验证:"
echo "  kubectl get pods -n ${NAMESPACE} -o wide"
echo "  kubectl get sc ${STORAGE_CLASS_NAME} -o yaml"
echo "  kubectl get pv"
echo "  sed -e 's|__NAMESPACE__|${NAMESPACE}|' -e 's|__STORAGE_CLASS_NAME__|${STORAGE_CLASS_NAME}|' \"${TEST_YAML}\" | kubectl apply -f -"
echo "  kubectl get pvc,pod -n ${NAMESPACE} -o wide"
echo "  kubectl exec -n ${NAMESPACE} local-ssd-test-pod -- ls -l /data"
echo
echo "生产说明:"
echo "  - reclaimPolicy=${RECLAIM_POLICY}"
echo "  - 生产推荐一块盘/分区一个挂载点,例如 ${HOST_DIR}/ssd1、${HOST_DIR}/ssd2"
echo "  - 多块同类 SSD 共用一个 StorageClass 即可,Pod 副本分散靠 workload 自己配置"
if [ "$RECLAIM_POLICY" = "Retain" ]; then
  echo "  - PVC 删除后本地数据不会自动回收,需人工检查并清理目录后再复用"
else
  echo "  - 当前使用 Delete,更适合测试/临时数据场景"
fi
echo
echo "卸载:"
echo "  bash ${SCRIPT_DIR}/uninstall.sh --apply"
