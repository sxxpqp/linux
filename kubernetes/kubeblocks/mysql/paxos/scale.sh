#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/mysql/paxos/scale.sh
# KubeBlocks MySQL Paxos 集群扩缩容 (改 replicas 数).
#
# Paxos 多数派要求:
#   - replicas 必须是 **奇数** (3 / 5 / 7), 偶数会导致脑裂或选不出 leader
#   - 最小 3 副本, 不能缩到 1
#   - 推荐 3 或 5; 7 已经接近 Paxos 性能拐点 (broadcast 放大)
#
# 用法:
#   bash scale.sh 5                 # replicas → 5
#   bash scale.sh --to 5 --ns prod
#   bash scale.sh --wait 5          # 等 OpsRequest 完成
set -uo pipefail

NS="test"
CLUSTER="mysql-paxos"
COMPONENT="mysql"
WAIT=false
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)        NS="$2"; shift 2 ;;
    --to)        TARGET="$2"; shift 2 ;;
    --cluster)   CLUSTER="$2"; shift 2 ;;
    --component) COMPONENT="$2"; shift 2 ;;
    --wait)      WAIT=true; shift ;;
    -h|--help)
      sed -n '2,13p' "$0" | sed 's/^# //'
      exit 0 ;;
    -*)
      echo "未知参数: $1"; exit 1 ;;
    *)
      [ -z "$TARGET" ] && TARGET="$1" || { echo "多余参数: $1"; exit 1; }
      shift ;;
  esac
done

if [ -z "$TARGET" ]; then
  echo "ERROR: 必须指定目标 replicas 数, 例如: bash scale.sh 5"
  exit 1
fi
if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  echo "ERROR: replicas 必须是数字: ${TARGET}"
  exit 1
fi
if [ "$TARGET" -lt 3 ]; then
  echo "ERROR: Paxos 多数派至少 3 副本 (你设了 ${TARGET})"
  exit 1
fi
if [ $((TARGET % 2)) -eq 0 ]; then
  echo "ERROR: Paxos replicas 必须是奇数 (3/5/7), 你设了 ${TARGET}"
  echo "  偶数会导致多数派无法形成, 集群不可写"
  exit 1
fi

CURRENT=$(kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
  -o jsonpath="{.spec.componentSpecs[?(@.name=='${COMPONENT}')].replicas}" 2>/dev/null || echo "")

if [ -z "$CURRENT" ]; then
  echo "ERROR: 找不到 cluster.${CLUSTER} 的 component=${COMPONENT}"
  exit 1
fi

echo "========================================="
echo " MySQL Paxos 集群扩缩容"
echo "  namespace:   ${NS}"
echo "  cluster:     ${CLUSTER}"
echo "  component:   ${COMPONENT}"
echo "  当前 replicas: ${CURRENT}"
echo "  目标 replicas: ${TARGET}  (Paxos 多数派 = $(((TARGET / 2) + 1)))"
echo "========================================="
echo ""

if [ "$CURRENT" = "$TARGET" ]; then
  echo "replicas 已经是 ${TARGET}, 无需操作"
  exit 0
fi

DELTA=$((TARGET - CURRENT))
if [ "$DELTA" -gt 0 ]; then
  echo "→ 扩容: +${DELTA} 副本"
else
  echo "→ 缩容: -$((-DELTA)) 副本 (注意: 缩容会触发 Paxos 成员变更, 务必逐步)"
fi
echo ""

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
      replicas: ${TARGET}
EOF

echo ""
echo "OpsRequest 已创建: ${OPS_NAME}"
echo ""
echo "查看进度:"
echo "  kubectl get opsrequest ${OPS_NAME} -n ${NS} -w"
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=${CLUSTER}"
echo ""

if [ "$WAIT" = true ]; then
  echo "等待 OpsRequest 完成..."
  for i in $(seq 1 60); do
    PHASE=$(kubectl get opsrequest "${OPS_NAME}" -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/60] phase=${PHASE:-<empty>}"
    case "$PHASE" in
      Succeed) echo "  ✓ 完成"; break ;;
      Failed|Aborted)
        echo "  ✗ ${PHASE}"
        kubectl get opsrequest "${OPS_NAME}" -n "${NS}" \
          -o jsonpath='{.status.conditions}' | python3 -m json.tool 2>/dev/null || true
        exit 1 ;;
    esac
    sleep 10
  done
fi

echo ""
echo "当前 pod 及角色 (Paxos: leader / follower):"
kubectl get pod -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" \
  -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.kubeblocks\.io/role,STATUS:.status.phase'
