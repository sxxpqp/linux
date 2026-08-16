#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/minio/scale.sh
# KubeBlocks MinIO 水平扩缩容 (改 replicas 数).
#
# ⚠ 重要: MinIO 纠删码要求 replicas 必须为偶数 (2/4/6/8/12...)
# ⚠ 已知问题: 扩容后新节点需 STOP→START 才能正常加入集群 (官方 README 说明)
#    本脚本在 --wait 模式下会自动执行 STOP→START
#
# 用法:
#   bash scale.sh 6                 # replicas → 6
#   bash scale.sh --to 8 --ns prod
#   bash scale.sh --wait 6          # 等到完成 + 自动 STOP→START
set -uo pipefail

NS="test"
WAIT=false
CLUSTER="minio-cluster"
COMPONENT="minio"
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)        NS="$2"; shift 2 ;;
    --to)        TARGET="$2"; shift 2 ;;
    --cluster)   CLUSTER="$2"; shift 2 ;;
    --component) COMPONENT="$2"; shift 2 ;;
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
  echo "ERROR: 必须指定目标 replicas 数, 例如: bash scale.sh 6"
  exit 1
fi
if ! [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  echo "ERROR: replicas 必须是数字: ${TARGET}"
  exit 1
fi
if [ "$TARGET" -lt 2 ]; then
  echo "ERROR: MinIO 最少 2 副本"
  exit 1
fi
if [ $((TARGET % 2)) -ne 0 ]; then
  echo "ERROR: MinIO replicas 必须为偶数 (纠删码要求), 你设了 ${TARGET}"
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
echo " MinIO 水平扩缩容"
echo "  namespace:     ${NS}"
echo "  cluster:       ${CLUSTER}"
echo "  component:     ${COMPONENT}"
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
  OPS_TYPE="scaleOut"
else
  echo "→ 缩容: -$((-DELTA)) 副本"
  OPS_TYPE="scaleIn"
fi
echo ""

OPS_NAME="${CLUSTER}-scale-$(date +%s)"

if [ "$DELTA" -gt 0 ]; then
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
      scaleOut:
        replicaChanges: ${DELTA}
EOF
else
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
      scaleIn:
        replicaChanges: $((-DELTA))
EOF
fi

echo ""
echo "OpsRequest 已创建: ${OPS_NAME}"
echo ""

if [ "$WAIT" = true ]; then
  echo "等待 OpsRequest 完成..."
  for i in $(seq 1 120); do
    PHASE=$(kubectl get opsrequest "${OPS_NAME}" -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/120] phase=${PHASE:-<empty>}"
    case "$PHASE" in
      Succeed) echo "  ✓ 扩缩容完成"; break ;;
      Failed|Aborted)
        echo "  ✗ ${PHASE}"
        kubectl get opsrequest "${OPS_NAME}" -n "${NS}" -o yaml
        exit 1 ;;
    esac
    sleep 5
  done

  # 扩容后需要 STOP→START 让新节点加入集群 (官方已知问题)
  if [ "$DELTA" -gt 0 ]; then
    echo ""
    echo "⚠ 扩容后执行 STOP→START 让新节点正常加入集群..."
    
    STOP_NAME="${CLUSTER}-stop-$(date +%s)"
    cat <<EOF | kubectl apply -f -
apiVersion: operations.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: ${STOP_NAME}
  namespace: ${NS}
spec:
  clusterName: ${CLUSTER}
  force: true
  type: Stop
EOF
    echo "  STOP OpsRequest: ${STOP_NAME}"
    
    for i in $(seq 1 60); do
      PHASE=$(kubectl get opsrequest "${STOP_NAME}" -n "${NS}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
      echo "  [$i/60] STOP phase=${PHASE:-<empty>}"
      [ "$PHASE" = "Succeed" ] && break
      [ "$PHASE" = "Failed" ] && { echo "  ✗ STOP 失败"; exit 1; }
      sleep 5
    done

    START_NAME="${CLUSTER}-start-$(date +%s)"
    cat <<EOF | kubectl apply -f -
apiVersion: operations.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: ${START_NAME}
  namespace: ${NS}
spec:
  clusterName: ${CLUSTER}
  force: true
  type: Start
EOF
    echo "  START OpsRequest: ${START_NAME}"
    
    for i in $(seq 1 60); do
      PHASE=$(kubectl get opsrequest "${START_NAME}" -n "${NS}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)
      echo "  [$i/60] START phase=${PHASE:-<empty>}"
      [ "$PHASE" = "Succeed" ] && break
      [ "$PHASE" = "Failed" ] && { echo "  ✗ START 失败"; exit 1; }
      sleep 5
    done
    echo "  ✓ STOP→START 完成, 新节点已加入集群"
  fi
else
  echo "查看进度:"
  echo "  kubectl get opsrequest ${OPS_NAME} -n ${NS} -w"
  if [ "$DELTA" -gt 0 ]; then
    echo ""
    echo "⚠ 扩容完成后需手动 STOP→START (或重跑 bash scale.sh --wait ${TARGET}):"
    echo "  参考官方文档: 新节点需重启才能正常加入纠删码集群"
  fi
fi

echo ""
echo "当前 cluster:"
kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" -o wide
echo ""
echo "当前 pod:"
kubectl get pod -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" -o wide
