#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/redis-cluster/scale.sh
# KubeBlocks Redis Sharding Cluster 扩缩容 (改 shards 数, 不是 replicas).
# 一个 shard = 1 master + 1 replica = 2 pod.
# 例: scale.sh 4 表示 4 个分片 = 8 pod (4 master 各分 ~4096 个槽位).
#
# 用法:
#   bash scale.sh 4                 # shards → 4
#   bash scale.sh --to 5 --ns prod
#   bash scale.sh --wait 4          # 等到 OpsRequest 完成 (扩容含 reshard 耗时长)
#
# 注意:
#   - shards 最小 3 (Redis Cluster 至少 3 master 才能选举 quorum)
#   - 扩容: operator 起新 shard → CLUSTER MEET → 迁部分槽位过去 → AVAILABLE
#   - 缩容: operator 先把目标 shard 槽位迁走 → 再删 pod
set -uo pipefail

NS="test"
WAIT=false
CLUSTER="redis-cluster"
SHARDING="shard"
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)        NS="$2"; shift 2 ;;
    --to)        TARGET="$2"; shift 2 ;;
    --cluster)   CLUSTER="$2"; shift 2 ;;
    --sharding)  SHARDING="$2"; shift 2 ;;
    --wait)      WAIT=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# //'
      exit 0 ;;
    -*)
      echo "未知参数: $1"; exit 1 ;;
    *)
      [ -z "$TARGET" ] && TARGET="$1" || { echo "多余参数: $1"; exit 1; }
      shift ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "ERROR: 必须指定目标 shard 数, 例如: bash scale.sh 4"
  exit 1
fi
if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  echo "ERROR: shard 数必须是数字: ${TARGET}"
  exit 1
fi
if [ "$TARGET" -lt 3 ]; then
  echo "WARN: Redis Cluster 至少 3 shard (3 master), 你设了 ${TARGET}"
fi

# 当前 shard 数 (v1 API 路径: spec.shardings[].shards)
CURRENT=$(kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
  -o jsonpath="{.spec.shardings[?(@.name=='${SHARDING}')].shards}" 2>/dev/null || echo "")

if [ -z "$CURRENT" ]; then
  echo "ERROR: 找不到 cluster.${CLUSTER} 的 sharding=${SHARDING}"
  echo "       查询: kubectl get cluster -n ${NS} -o jsonpath='{.spec.shardings[*].name}'"
  exit 1
fi

echo "========================================="
echo " Redis Cluster 扩缩容 (sharding)"
echo "  namespace:     ${NS}"
echo "  cluster:       ${CLUSTER}"
echo "  sharding:      ${SHARDING}"
echo "  当前 shards:   ${CURRENT}  (= $((CURRENT * 2)) pod)"
echo "  目标 shards:   ${TARGET}   (= $((TARGET * 2)) pod)"
echo "========================================="
echo ""

if [ "$CURRENT" = "$TARGET" ]; then
  echo "shard 数已经是 ${TARGET}, 无需操作"
  exit 0
fi

DELTA=$((TARGET - CURRENT))
if [ "$DELTA" -gt 0 ]; then
  echo "→ 扩容: +${DELTA} shard (operator 自动加 master + reshard 槽位)"
else
  echo "→ 缩容: -$((-DELTA)) shard (operator 先迁槽位再删 pod)"
fi
echo ""

# OpsRequest 改 sharding 的 shards 字段
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
    - componentName: ${SHARDING}
      shards: ${TARGET}
EOF

echo ""
echo "OpsRequest 已创建: ${OPS_NAME}"
echo ""
echo "查看进度:"
echo "  kubectl get opsrequest ${OPS_NAME} -n ${NS} -w"
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=${CLUSTER}"
echo ""

if [ "$WAIT" = true ]; then
  echo "等待 OpsRequest 完成 (扩容含 reshard, 数据多时较慢)..."
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
echo "当前 cluster:"
kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" -o wide
echo ""
echo "当前 component (每个 shard 对应一个):"
kubectl get component -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" 2>/dev/null
