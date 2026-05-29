#!/bin/bash
# KubeBlocks Redis Cluster 扩缩容 (通过 OpsRequest, operator 自动 reshard)。
# 用法:
#   bash scale.sh 9                 # 改 replicas 到 9 (operator 自动判断扩还是缩)
#   bash scale.sh --to 12 --ns prod # 指定 namespace
#   bash scale.sh --wait 9          # 等到 OpsRequest 完成
#
# 注意:
#   - Redis Cluster 副本数必须是 master+replicas 的总和, master 至少 3
#   - 扩容自动加 master 并 reshard 槽位 (耗时取决于数据量)
#   - 缩容前 operator 会先把目标节点的槽位迁走, 再删 Pod
set -uo pipefail

NS="test"
WAIT=false
CLUSTER="redis-cluster"
COMPONENT="redis-cluster"
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)        NS="$2"; shift 2 ;;
    --to)        TARGET="$2"; shift 2 ;;
    --cluster)   CLUSTER="$2"; shift 2 ;;
    --component) COMPONENT="$2"; shift 2 ;;
    --wait)      WAIT=true; shift ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# //'
      exit 0 ;;
    -*)
      echo "未知参数: $1"; exit 1 ;;
    *)
      # 第一个非 flag 参数视为目标副本数
      [ -z "$TARGET" ] && TARGET="$1" || { echo "多余参数: $1"; exit 1; }
      shift ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "ERROR: 必须指定目标副本数, 例如: bash scale.sh 9"
  exit 1
fi

if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  echo "ERROR: 副本数必须是数字: ${TARGET}"
  exit 1
fi

if [ "$TARGET" -lt 6 ]; then
  echo "WARN: Redis Cluster 最小 6 副本 (3主3从), 你设了 ${TARGET}"
fi

# 当前副本数
CURRENT=$(kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
  -o jsonpath="{.spec.componentSpecs[?(@.name=='${COMPONENT}')].replicas}" 2>/dev/null || echo "")

if [ -z "$CURRENT" ]; then
  echo "ERROR: 找不到 cluster.${CLUSTER} 的 component=${COMPONENT}"
  echo "       查询: kubectl get cluster -n ${NS}"
  exit 1
fi

echo "========================================="
echo " Redis Cluster 扩缩容"
echo "  namespace:  ${NS}"
echo "  cluster:    ${CLUSTER}"
echo "  component:  ${COMPONENT}"
echo "  当前副本数: ${CURRENT}"
echo "  目标副本数: ${TARGET}"
echo "========================================="
echo ""

if [ "$CURRENT" = "$TARGET" ]; then
  echo "副本数已经是 ${TARGET}, 无需操作"
  exit 0
fi

# 计算变更
DELTA=$((TARGET - CURRENT))
if [ "$DELTA" -gt 0 ]; then
  ACTION="scaleOut"
  CHANGE="$DELTA"
  echo "→ 扩容: +${DELTA} 副本"
else
  ACTION="scaleIn"
  CHANGE=$((-DELTA))
  echo "→ 缩容: -${CHANGE} 副本"
fi
echo ""

# 创建 OpsRequest
OPS_NAME="${CLUSTER}-scale-$(date +%s)"
cat <<EOF | kubectl apply -f -
apiVersion: operations.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: ${OPS_NAME}
  namespace: ${NS}
spec:
  clusterName: ${CLUSTER}
  type: HorizontalScaling
  horizontalScaling:
    - componentName: ${COMPONENT}
      ${ACTION}:
        replicaChanges: ${CHANGE}
EOF

echo ""
echo "OpsRequest 已创建: ${OPS_NAME}"
echo ""
echo "查看进度:"
echo "  kubectl get opsrequest ${OPS_NAME} -n ${NS} -w"
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=${CLUSTER}"
echo ""

if [ "$WAIT" = true ]; then
  echo "等待 OpsRequest 完成 (扩容含 reshard 耗时可能较长)..."
  for i in $(seq 1 120); do
    PHASE=$(kubectl get opsrequest "${OPS_NAME}" -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/120] phase=${PHASE:-<empty>}"
    case "$PHASE" in
      Succeed) echo "  ✓ 完成"; break ;;
      Failed|Aborted)
        echo "  ✗ ${PHASE}"
        kubectl get opsrequest "${OPS_NAME}" -n "${NS}" \
          -o jsonpath='{.status.conditions}' | python3 -m json.tool 2>/dev/null || true
        exit 1 ;;
    esac
    sleep 5
  done
fi

echo ""
echo "当前 cluster 状态:"
kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" -o wide
