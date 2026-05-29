#!/bin/bash
# 安装 KubeBlocks operator (按官方三步: CRD → operator → addons)。
# 参考: https://kubeblocks.io/docs/preview/user_docs/overview/install-kubeblocks
#
# 用法:
#   bash install.sh                            # 默认 v0.9.3
#   bash install.sh --version v1.0.0           # 指定版本
#   bash install.sh --addons redis,mysql       # 只装这两个 addon (逗号分隔)
#   bash install.sh --skip-addons              # 只装 core, 不装 addon
#   bash install.sh --public                   # 用 apecloud 公网 helm 仓库 (默认走内网 nexus)
set -uo pipefail

NAMESPACE="kb-system"
VERSION="v1.0.2"
ADDONS="redis,mysql,postgresql,mongodb,kafka"
SKIP_ADDONS=false
USE_PUBLIC=false

# 仓库地址 - 内网 nexus 代理 / 公网 ApeCloud
NEXUS_REPO="https://nexus.ihome.sxxpqp.top:8443/repository/helm-apecloud"
PUBLIC_REPO="https://apecloud.github.io/helm-charts"

# CRD 文件下载地址 (内网共享镜像优先, GitHub 兜底)
# 内网地址按版本拼接, 比如 v1.0.2 → kubeblocks_crds.yaml
CRD_URL_INTERNAL="https://chfs.sxxpqp.top:8443/chfs/shared/k8s/kubeblocks/kubeblocks_crds.yaml"

for ((i=1; i<=$#; i++)); do
  case "${!i}" in
    --version)     i=$((i+1)); VERSION="${!i}" ;;
    --addons)      i=$((i+1)); ADDONS="${!i}" ;;
    --skip-addons) SKIP_ADDONS=true ;;
    --public)      USE_PUBLIC=true ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: ${!i} (使用 --help 查看用法)"
      exit 1 ;;
  esac
done

# 版本号统一带 v 前缀 (helm chart 版本不带 v, CRD release tag 带 v)
VERSION_NO_V="${VERSION#v}"
VERSION_WITH_V="v${VERSION_NO_V}"

REPO_URL=$([ "$USE_PUBLIC" = true ] && echo "$PUBLIC_REPO" || echo "$NEXUS_REPO")

echo "========================================="
echo " KubeBlocks 安装"
echo "  namespace:   ${NAMESPACE}"
echo "  version:     ${VERSION_WITH_V}"
echo "  helm repo:   ${REPO_URL}"
echo "  addons:      $([ "$SKIP_ADDONS" = true ] && echo "(skip)" || echo "${ADDONS}")"
echo "========================================="
echo ""

# ---------- 前置 ----------
if ! command -v helm &>/dev/null; then
  echo "ERROR: helm 未安装"; exit 1
fi
if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl 未安装"; exit 1
fi

# ---------- 1. Helm 仓库 ----------
echo "[1/5] 配置 KubeBlocks helm 仓库..."
helm repo remove kubeblocks 2>/dev/null || true
helm repo add kubeblocks "${REPO_URL}"
helm repo update kubeblocks >/dev/null
echo "  ✓ kubeblocks repo: ${REPO_URL}"
echo ""

# ---------- 2. CRD (官方要求必须先装) ----------
# 用 server-side apply, 避免 last-applied annotation 256KB 上限
# (KubeBlocks CRD 加起来 > 1MB)
echo "[2/5] 安装 KubeBlocks CRD..."
CRD_URL_GITHUB="https://github.com/apecloud/kubeblocks/releases/download/${VERSION_WITH_V}/kubeblocks_crds.yaml"

# 用一个 sentinel CRD 来判断是否真的注册成功 (kubeblocks 装齐后必有它)
crd_ready() {
  kubectl get crd clusters.apps.kubeblocks.io &>/dev/null \
    && kubectl get crd addons.extensions.kubeblocks.io &>/dev/null
}

try_apply_crd() {
  local url="$1"
  echo "  尝试: ${url}"
  kubectl apply --server-side -f "${url}" 2>&1 | grep -vE "^$" | tail -n +1
  crd_ready
}

CRD_OK=false
if try_apply_crd "${CRD_URL_INTERNAL}"; then
  CRD_OK=true
elif try_apply_crd "${CRD_URL_GITHUB}"; then
  CRD_OK=true
else
  echo "  尝试从 helm chart 提取..."
  helm template kubeblocks kubeblocks/kubeblocks --version "${VERSION_NO_V}" \
    --include-crds 2>/dev/null \
    | kubectl apply --server-side -f - >/dev/null 2>&1
  crd_ready && CRD_OK=true
fi

if [ "$CRD_OK" = false ]; then
  echo ""
  echo "  ERROR: CRD 安装全部失败. 离线环境请手动:"
  echo "    curl -kL -o kubeblocks_crds.yaml ${CRD_URL_INTERNAL}"
  echo "    kubectl apply --server-side -f kubeblocks_crds.yaml"
  exit 1
fi
echo "  ✓ CRD 已就绪 ($(kubectl get crd -o name | grep -c kubeblocks.io) 个)"
echo ""

# ---------- 3. Namespace ----------
echo "[3/5] 创建命名空间 ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ---------- 4. KubeBlocks Operator ----------
echo "[4/5] 安装 KubeBlocks operator..."
if ! helm upgrade --install kubeblocks kubeblocks/kubeblocks \
  --namespace "${NAMESPACE}" \
  --version "${VERSION_NO_V}" \
  --set crd.enabled=false \
  --wait --timeout 5m; then
  echo ""
  echo "ERROR: KubeBlocks chart 安装失败. 常见原因:"
  echo "  1. helm 仓库地址错: helm search repo kubeblocks/kubeblocks --versions"
  echo "  2. version (${VERSION_NO_V}) 不存在于该仓库: 改 --version 或换 --public 公网"
  echo "  3. CRD 未就绪: kubectl get crd | grep kubeblocks"
  exit 1
fi
echo ""

# ---------- 5. Addons ----------
if [ "$SKIP_ADDONS" = false ]; then
  echo "[5/5] 安装 addons: ${ADDONS}..."

  # 等 Addon CRD 注册完成
  echo "  等待 Addon CRD 注册..."
  for i in $(seq 1 30); do
    if kubectl get crd addons.extensions.kubeblocks.io &>/dev/null; then
      break
    fi
    sleep 2
  done

  if ! kubectl get crd addons.extensions.kubeblocks.io &>/dev/null; then
    echo "  ERROR: Addon CRD 没注册成功"
    exit 1
  fi

  # v0.9+ 每个 addon 是独立 helm chart
  IFS=',' read -ra ADDON_ARR <<< "${ADDONS}"
  for addon in "${ADDON_ARR[@]}"; do
    addon=$(echo "$addon" | xargs)  # trim
    echo "  安装 addon: ${addon}"
    helm upgrade --install "${addon}" "kubeblocks/${addon}" \
      --namespace "${NAMESPACE}" \
      --version "${VERSION_NO_V}" \
      --wait --timeout 3m 2>&1 \
      | sed 's/^/    /' || echo "    (${addon} 安装失败, 可能仓库里没这个 chart)"
  done
else
  echo "[5/5] 跳过 addon (--skip-addons)"
fi

echo ""
echo "========================================="
echo " 安装完成"
echo "========================================="
echo ""
echo "operator pod:"
kubectl get pod -n "${NAMESPACE}"
echo ""
echo "已启用的 addon:"
kubectl get addon 2>/dev/null | head -20 || echo "  (Addon CRD 还未注册, 等几秒)"
echo ""
echo "下一步:"
echo "  cd redis-cluster/"
echo "  bash deploy.sh         # 创建一个 Redis Cluster 实例"
