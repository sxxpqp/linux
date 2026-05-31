#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/redis-cluster/restart.sh
# KubeBlocks Redis Sharding Cluster 滚动重启.
#
# 重启期间 master 所在的 shard 会先 failover 到 slave, 再重启原 master 节点.
# 业务侧开 cluster client + 重试, 通常 0-3s 间歇重连, 无数据丢失.
#
# 用法:
#   bash restart.sh                  # 默认 ns=test
#   bash restart.sh --ns prod
#   bash restart.sh --wait           # 等到完成
set -uo pipefail

NS="test"
WAIT=false
CLUSTER="redis-cluster"
SHARDING="shard"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)        NS="$2"; shift 2 ;;
    --cluster)   CLUSTER="$2"; shift 2 ;;
    --sharding)  SHARDING="$2"; shift 2 ;;
    --wait)      WAIT=true; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
  esac
done

# 检查 cluster 存在
if ! kubectl get cluster.apps.kubeblocks.io "${CLUSTER}" -n "${NS}" &>/dev/null; then
  echo "ERROR: Cluster ${CLUSTER} 不存在于 namespace ${NS}"
  exit 1
fi

echo "========================================="
echo " Redis Cluster 滚动重启"
echo "  namespace: ${NS}"
echo "  cluster:   ${CLUSTER}"
echo "  sharding:  ${SHARDING}"
echo "========================================="
echo ""

OPS_NAME="${CLUSTER}-restart-$(date +%s)"

kubectl apply -f - <<EOF
apiVersion: operations.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: ${OPS_NAME}
  namespace: ${NS}
spec:
  clusterName: ${CLUSTER}
  type: Restart
  restart:
    - componentName: ${SHARDING}
EOF

echo ""
echo "OpsRequest 已创建: ${OPS_NAME}"
echo ""

if [ "$WAIT" = true ]; then
  echo "等待重启完成..."
  for i in $(seq 1 120); do
    PHASE=$(kubectl get opsrequest "${OPS_NAME}" -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    PROGRESS=$(kubectl get opsrequest "${OPS_NAME}" -n "${NS}" \
      -o jsonpath='{.status.components[0].progressDetails}' 2>/dev/null || true)
    echo "  [$i/120] phase=${PHASE:-<empty>}  progress=${PROGRESS:-<none>}"
    case "$PHASE" in
      Succeed)
        echo "  ✓ 重启完成"
        break ;;
      Failed|Aborted)
        echo "  ✗ ${PHASE}"
        kubectl get opsrequest "${OPS_NAME}" -n "${NS}" -o yaml
        exit 1 ;;
    esac
    sleep 5
  done
else
  echo "查看进度:"
  echo "  kubectl get opsrequest ${OPS_NAME} -n ${NS} -w"
fi

echo ""
echo "当前 pod:"
kubectl get pod -n "${NS}" -l app.kubernetes.io/instance="${CLUSTER}" -o wide
