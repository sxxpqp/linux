#!/bin/bash
# 部署 RedisInsight (Redis 官方 GUI, 原生支持 Cluster 模式).
# 集群内一个 pod, NodePort 暴露 Web UI, 浏览器直接用.
#
# 用法:
#   bash redisinsight-install.sh                       # 装到 test ns
#   bash redisinsight-install.sh --ns prod
#   bash redisinsight-install.sh --nodeport 31501      # 改 NodePort (默认 31501)
#   bash redisinsight-install.sh --image my/redisinsight:latest
#   bash redisinsight-install.sh --wait                # 等就绪 + 打印连接信息
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
NODEPORT=""
IMAGE=""
WAIT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)       NS="$2"; shift 2 ;;
    --nodeport) NODEPORT="$2"; shift 2 ;;
    --image)    IMAGE="$2"; shift 2 ;;
    --wait)     WAIT=true; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 1. namespace ----------
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---------- 2. 渲染 yaml ----------
TMP_YAML=$(mktemp)
sed "s|namespace: test|namespace: ${NS}|g" "${DIR}/redisinsight.yaml" > "${TMP_YAML}"

[ -n "${NODEPORT}" ] && sed -i "s|nodePort: 31501|nodePort: ${NODEPORT}|g" "${TMP_YAML}"
[ -n "${IMAGE}" ]    && sed -i "s|image: redis/redisinsight:latest|image: ${IMAGE}|g" "${TMP_YAML}"

# ---------- 3. 部署 ----------
echo "部署 RedisInsight 到 ns=${NS}..."
kubectl apply -f "${TMP_YAML}"
rm -f "${TMP_YAML}"

if [ "$WAIT" = true ]; then
  echo "等就绪..."
  kubectl -n "${NS}" rollout status deploy/redisinsight --timeout=180s || {
    echo "✗ pod 没起来"
    kubectl -n "${NS}" get pod -l app=redisinsight
    kubectl -n "${NS}" logs -l app=redisinsight --tail=30
    exit 1
  }
fi

# ---------- 4. 连接信息 ----------
NP=$(kubectl get svc redisinsight -n "${NS}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
NODE_IPS=$(kubectl get node -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}')
NODE_IP=$(echo "$NODE_IPS" | awk '{print $1}')
ACTUAL_PASS=$(kubectl get secret redis-cluster-password -n "${NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

echo ""
echo "================================================================="
echo " ✓ RedisInsight 已部署"
echo "================================================================="
echo ""
echo "Web UI:"
echo "  http://${NODE_IP}:${NP}"
echo "  (任一 node IP 都可以: ${NODE_IPS})"
echo ""
echo "在 RedisInsight 中添加 database:"
echo "  Connection type:    Redis OSS Cluster"
echo "  Host:               redis-cluster-shard-jqf-headless.${NS}.svc"
echo "  Port:               6379"
echo "  Username:           (空)"
echo "  Password:           ${ACTUAL_PASS:-<从 Secret/redis-cluster-password 取>}"
echo "  Database alias:     redis-cluster"
echo ""
echo "取密码命令:"
echo "  kubectl get secret redis-cluster-password -n ${NS} -o jsonpath='{.data.password}' | base64 -d; echo"
