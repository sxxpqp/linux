#!/bin/bash
# 部署 KubeBlocks Redis Cluster 实例 (3主3从)。
# 用法:
#   bash install.sh                # 部署到 test namespace (cluster.yaml 默认值)
#   bash install.sh --ns prod      # 改 namespace
#   bash install.sh --wait         # 部署后等待 cluster 完全 Running
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false

for ((i=1; i<=$#; i++)); do
  case "${!i}" in
    --ns)   i=$((i+1)); NS="${!i}" ;;
    --wait) WAIT=true ;;
    -h|--help)
      sed -n '2,6p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: ${!i}"; exit 1 ;;
  esac
done

# 前置检查: KubeBlocks operator 必须已装
if ! kubectl get crd clusters.apps.kubeblocks.io &>/dev/null; then
  echo "ERROR: KubeBlocks operator 未安装 (找不到 Cluster CRD)"
  echo "       先跑: bash ../install.sh"
  exit 1
fi

# 创建 namespace
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# 替换 namespace 并 apply
echo "部署 Redis Cluster 到 namespace=${NS}..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/cluster.yaml" | kubectl apply -f -

echo ""
echo "查看进度:"
echo "  kubectl get cluster.apps.kubeblocks.io redis-cluster -n ${NS} -w"
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=redis-cluster"
echo ""

if [ "$WAIT" = true ]; then
  echo "等待 cluster 进入 Running 状态 (可能需要几分钟)..."
  for i in $(seq 1 60); do
    STATUS=$(kubectl get cluster.apps.kubeblocks.io redis-cluster -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/60] cluster.status.phase = ${STATUS:-<empty>}"
    [ "$STATUS" = "Running" ] && break
    sleep 10
  done
fi

echo ""
echo "连接信息:"
kubectl get svc -n "${NS}" -l app.kubernetes.io/instance=redis-cluster 2>/dev/null
echo ""
echo "获取密码:"
echo "  kubectl get secret redis-cluster-conn-credential -n ${NS} -o jsonpath='{.data.password}' | base64 -d"
