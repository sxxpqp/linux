#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/kafka/scale.sh
# KubeBlocks Kafka Cluster 扩缩容 (改 broker replicas 数).
#
# Kafka KRaft combined 模式中 broker 和 controller 是同 pod, 扩容同时增加
# broker 和 controller 节点. KRaft controller 要求奇数个 (1/3/5...).
#
# 用法:
#   bash scale.sh 5                 # replicas → 5
#   bash scale.sh --to 5 --ns prod
#   bash scale.sh --wait 5          # 等到 OpsRequest 完成
set -uo pipefail

NS="test"
WAIT=false
CLUSTER="kafka-cluster"
COMPONENT="kafka-combine"
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
  echo "ERROR: 必须指定目标 broker 数, 例如: bash scale.sh 5"
  exit 1
fi
if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  echo "ERROR: replicas 必须是数字: ${TARGET}"
  exit 1
fi

# 当前 replicas
CURRENT=$(kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" \
  -o jsonpath="{.spec.componentSpecs[?(@.name=='${COMPONENT}')].replicas}" 2>/dev/null || echo "")

if [ -z "$CURRENT" ]; then
  echo "ERROR: 找不到 cluster.${CLUSTER} 的 component=${COMPONENT}"
  exit 1
fi

echo "========================================="
echo " Kafka Cluster 扩缩容"
echo "  namespace:   ${NS}"
echo "  cluster:     ${CLUSTER}"
echo "  component:   ${COMPONENT}"
echo "  当前 broker: ${CURRENT}"
echo "  目标 broker: ${TARGET}"
echo "========================================="
echo ""

if [ "$CURRENT" = "$TARGET" ]; then
  echo "broker 数已经是 ${TARGET}, 无需操作"
  exit 0
fi

DELTA=$((TARGET - CURRENT))
if [ "$DELTA" -gt 0 ]; then
  echo "→ 扩容: +${DELTA} broker"
else
  echo "→ 缩容: -$((-DELTA)) broker"
fi

# 检查奇数 (KRaft controller 多数派要求)
if [ $((TARGET % 2)) -eq 0 ]; then
  echo "⚠ KRaft controller 建议奇数个 (当前目标 ${TARGET} 是偶数)"
fi
echo ""

OPS_NAME="${CLUSTER}-scale-$(date +%s)"

# OpsRequest 用增量值 (scaleOut / scaleIn), 不是绝对值
if [ "$DELTA" -gt 0 ]; then
  SCALE_FIELD="scaleOut"
else
  SCALE_FIELD="scaleIn"
  DELTA=$((-DELTA))
fi

kubectl apply -f - <<EOF
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
      ${SCALE_FIELD}:
        replicaChanges: ${DELTA}
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
  for i in $(seq 1 120); do
    PHASE=$(kubectl get opsrequest "${OPS_NAME}" -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/120] phase=${PHASE:-<empty>}"
    case "$PHASE" in
      Succeed) echo "  ✓ 完成"; break ;;
      Failed|Aborted)
        echo "  ✗ ${PHASE}"
        kubectl get opsrequest "${OPS_NAME}" -n "${NS}" -o yaml
        exit 1 ;;
    esac
    sleep 5
  done
fi

echo ""
echo "当前 cluster:"
kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" -o wide
