#!/bin/bash
# KubeBlocks MySQL 集群扩缩容 (改 replicas 数).
# 最小 3 副本 (1 主 + 2 从), 保证 HA 选举 quorum.
#
# 用法:
#   bash scale.sh 5                 # replicas → 5
#   bash scale.sh --to 5 --ns prod
#   bash scale.sh --wait 5          # 等 OpsRequest 完成
set -uo pipefail

NS="test"
CLUSTER="mysql-cluster"
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
      sed -n '2,9p' "$0" | sed 's/^# //'
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
  echo "WARN: MySQL HA 至少 3 副本, 你设了 ${TARGET}, 可能导致无法选举"
fi

CURRENT=$(kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
  -o jsonpath="{.spec.components[?(@.name=='${COMPONENT}')].replicas}" 2>/dev/null || echo "")

if [ -z "$CURRENT" ]; then
  echo "ERROR: 找不到 cluster.${CLUSTER} 的 component=${COMPONENT}"
  exit 1
fi

echo "========================================="
echo " MySQL 集群扩缩容"
echo "  namespace:   ${NS}"
echo "  cluster:     ${CLUSTER}"
echo "  component:   ${COMPONENT}"
echo "  当前 replicas: ${CURRENT}"
echo "  目标 replicas: ${TARGET}"
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
  echo "→ 缩容: -$((-DELTA)) 副本"
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
echo "当前 pod 及角色:"
kubectl get pod -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" \
  -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.kubeblocks\.io/role,STATUS:.status.phase'
