#!/bin/bash
# 部署 KubeBlocks Redis Sharding Cluster (3 shard × 2 副本 = 6 pod).
# 用法:
#   bash install.sh                       # 部署到 test, 密码自动生成 (随机 16 位)
#   bash install.sh --ns prod
#   bash install.sh --password 'xxx'      # 指定密码 (会写入 Secret redis-cluster-password)
#   bash install.sh --wait                # 等到 cluster.status.phase=Running
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false
PASSWORD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)       NS="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --wait)     WAIT=true; shift ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 前置检查 ----------
if ! kubectl get crd clusters.apps.kubeblocks.io &>/dev/null; then
  echo "ERROR: KubeBlocks operator 未安装"
  echo "       先跑: bash ../install.sh"
  exit 1
fi

# ---------- 1. namespace ----------
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# ---------- 2. 密码 Secret ----------
SECRET_NAME="redis-cluster-password"
if kubectl get secret "${SECRET_NAME}" -n "${NS}" &>/dev/null; then
  echo "[密码] 已存在 Secret/${SECRET_NAME} -n ${NS}, 复用"
  if [ -n "$PASSWORD" ]; then
    echo "  → 用 --password 提供的值覆盖"
    kubectl create secret generic "${SECRET_NAME}" -n "${NS}" \
      --from-literal=password="${PASSWORD}" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi
else
  if [ -z "$PASSWORD" ]; then
    # 生成 16 位随机密码 (字母数字, 不带特殊符号避免 redis-cli 转义麻烦)
    PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)
    echo "[密码] 自动生成: ${PASSWORD}"
  else
    echo "[密码] 使用 --password 提供的值"
  fi
  kubectl create secret generic "${SECRET_NAME}" -n "${NS}" \
    --from-literal=password="${PASSWORD}"
fi
echo ""

# ---------- 3. 部署 Cluster ----------
echo "部署 Redis Cluster 到 namespace=${NS}..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/cluster.yaml" | kubectl apply -f -

echo ""
echo "查看进度:"
echo "  kubectl get cluster.apps.kubeblocks.io redis-cluster -n ${NS} -w"
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=redis-cluster"
echo ""

# ---------- 4. 等就绪 ----------
if [ "$WAIT" = true ]; then
  echo "等待 cluster 进入 Running 状态 (3-5 分钟)..."
  for i in $(seq 1 60); do
    STATUS=$(kubectl get cluster.apps.kubeblocks.io redis-cluster -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/60] cluster.status.phase = ${STATUS:-<empty>}"
    [ "$STATUS" = "Running" ] && break
    [ "$STATUS" = "Failed" ] && { echo "  ✗ Failed, 查看日志诊断"; break; }
    sleep 10
  done
fi

# ---------- 5. 连接信息 ----------
echo ""
echo "========================================="
echo " 连接信息"
echo "========================================="
echo ""
echo "Service:"
kubectl get svc -n "${NS}" -l app.kubernetes.io/instance=redis-cluster 2>/dev/null
echo ""
echo "密码:"
echo "  kubectl get secret ${SECRET_NAME} -n ${NS} -o jsonpath='{.data.password}' | base64 -d; echo"
echo ""
echo "进 redis 任意 pod 测试 (集群健康):"
echo "  POD=\$(kubectl get pod -n ${NS} -l apps.kubeblocks.io/cluster-name=redis-cluster -o name | head -1)"
echo "  PASS=\$(kubectl get secret ${SECRET_NAME} -n ${NS} -o jsonpath='{.data.password}' | base64 -d)"
echo "  kubectl exec -n ${NS} \${POD#pod/} -c redis-cluster -- redis-cli -a \"\$PASS\" cluster info | head"
