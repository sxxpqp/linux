#!/bin/bash
# 安装 KubeBlocks operator (含 CRD)。
# KubeBlocks 是 ApeCloud 的 K8s 数据库 operator，支持 Redis/MySQL/PostgreSQL/Mongo/Kafka 等。
# 选它而不是 Bitnami chart 主要解决 Redis Cluster 的 IP 切换问题（用 InstanceSet 替代 StatefulSet）。
#
# 用法:
#   bash install.sh                           # 默认 v0.9.3
#   bash install.sh --version v1.0.0          # 指定版本
#   bash install.sh --skip-addons             # 只装 core，不装内置 addon (Redis/MySQL 等)
set -uo pipefail

NAMESPACE="kb-system"
VERSION="v0.9.3"
SKIP_ADDONS=false

for ((i=1; i<=$#; i++)); do
  case "${!i}" in
    --version)     i=$((i+1)); VERSION="${!i}" ;;
    --skip-addons) SKIP_ADDONS=true ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: ${!i} (使用 --help 查看用法)"
      exit 1 ;;
  esac
done

echo "========================================="
echo " KubeBlocks 安装"
echo "  namespace:  ${NAMESPACE}"
echo "  version:    ${VERSION}"
echo "  addons:     $([ "$SKIP_ADDONS" = true ] && echo "skip" || echo "install (Redis/MySQL/PG/Mongo/Kafka)")"
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
echo "[1/4] 添加 KubeBlocks helm 仓库..."
helm repo add kubeblocks https://nexus.ihome.sxxpqp.top:8443/repository/hwlm-longhorn/ --force-update 2>/dev/null || true
helm repo update >/dev/null

# ---------- 2. 命名空间 ----------
echo "[2/4] 创建命名空间 ${NAMESPACE}..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ---------- 3. 安装 CRD + Operator ----------
echo "[3/4] 安装 KubeBlocks core (CRD + operator)..."
helm upgrade --install kubeblocks kubeblocks/kubeblocks \
  --namespace "${NAMESPACE}" \
  --version "${VERSION}" \
  --set image.registry=apecloud-registry.cn-zhangjiakou.cr.aliyuncs.com \
  --wait --timeout 5m

# ---------- 4. 内置 Addon ----------
if [ "$SKIP_ADDONS" = false ]; then
  echo "[4/4] 启用内置 addons (Redis 等)..."
  for addon in redis mysql postgresql mongodb kafka; do
    echo "  启用 addon: ${addon}"
    kubectl patch addon "${addon}" --type=merge \
      -p '{"spec":{"install":{"enabled":true}}}' 2>/dev/null \
      || echo "  (${addon} 不存在或已启用)"
  done

  echo ""
  echo "等待 addon 就绪..."
  sleep 10
  kubectl get addon -A | grep -E "redis|mysql|postgresql|mongodb|kafka" || true
else
  echo "[4/4] 跳过 addon (--skip-addons)"
fi

echo ""
echo "========================================="
echo " 安装完成"
echo "========================================="
kubectl get pod -n "${NAMESPACE}"
echo ""
echo "下一步："
echo "  cd redis-cluster/"
echo "  bash deploy.sh         # 创建一个 Redis Cluster 实例"
