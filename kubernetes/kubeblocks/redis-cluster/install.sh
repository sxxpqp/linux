#!/bin/bash
# 部署 KubeBlocks Redis Sharding Cluster (3 shard × 2 副本 = 6 pod).
#
# 密码通过 systemAccounts.secretRef 引用外部 Secret, KubeBlocks 创建 pod 时
# 直接用 Secret 里的 password 设置 requirepass, 无需 post-deploy 轮换.
#
# 用法:
#   bash install.sh                 # 默认 ns=test
#   bash install.sh --ns prod
#   bash install.sh --wait          # 等到 Running
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false
SECRET_NAME="redis-cluster-password"
FIXED_PASS="${REDIS_PASS:-redis123}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)   NS="$2"; shift 2 ;;
    --wait) WAIT=true; shift ;;
    --pass) FIXED_PASS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 前置 ----------
if ! kubectl get crd clusters.apps.kubeblocks.io &>/dev/null; then
  echo "ERROR: KubeBlocks operator 未安装, 先跑 bash ../install.sh"
  exit 1
fi

# ---------- 1. namespace ----------
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# ---------- 2. 创建密码 Secret ----------
echo "创建 Secret/${SECRET_NAME} (username=default)..."
PASS_B64=$(printf '%s' "$FIXED_PASS" | base64 | tr -d '\n')
USER_B64=$(printf '%s' 'default' | base64 | tr -d '\n')
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NS}
data:
  password: ${PASS_B64}
  username: ${USER_B64}
immutable: true
EOF
echo ""

# ---------- 3. 部署 Cluster ----------
echo "部署 Redis Cluster 到 namespace=${NS}..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/cluster.yaml" | kubectl apply -f -
echo ""

# ---------- 4. 部署稳定 Service (跨 shard, 名字固定) ----------
echo "部署稳定 Service redis-cluster (业务代码引用这个, 不受 shard 后缀变化影响)..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/stable-service.yaml" | kubectl apply -f -
echo ""

# ---------- 5. 等就绪 ----------
if [ "$WAIT" = true ]; then
  echo "等 cluster.status.phase=Running (3-5 分钟)..."
  for i in $(seq 1 60); do
    STATUS=$(kubectl get cluster.apps.kubeblocks.io redis-cluster -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/60] phase=${STATUS:-<empty>}"
    [ "$STATUS" = "Running" ] && break
    [ "$STATUS" = "Failed" ] && { echo "  ✗ Failed"; break; }
    sleep 10
  done
  echo ""
fi

# ---------- 5. 连接信息汇总 ----------
echo ""
echo "==============================================================="
echo " ✓ 连接信息"
echo "==============================================================="

# ===== 密码 =====
echo ""
echo "------- 密码 -------"
echo "  密码:       ${FIXED_PASS}"
echo "  明文获取:   kubectl get secret ${SECRET_NAME} -n ${NS} -o jsonpath='{.data.password}' | base64 -d; echo"
echo "  base64:     PASS=\$(kubectl get secret ${SECRET_NAME} -n ${NS} -o jsonpath='{.data.password}')"

# ===== 集群内访问 =====
echo ""
echo "------- 集群内访问 (从 K8s pod 内连) -------"
echo ""
echo "  ⭐ 业务代码用这个稳定地址 (跨所有 shard, 名字固定):"
echo "      redis-cluster.${NS}.svc:6379"
echo ""

# 验证 stable service 真的指向 pod
STABLE_EP=$(kubectl get endpoints redis-cluster -n "${NS}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
echo "  当前 redis-cluster Service endpoints 数: ${STABLE_EP} (期望 6)"

if [ "${STABLE_EP}" -lt 6 ]; then
  echo ""
  echo "  ⚠ Service 没选到 6 个 pod, 可能 label 不匹配. 检查:"
  echo "    kubectl get pod -n ${NS} -l app.kubernetes.io/instance=redis-cluster,apps.kubeblocks.io/sharding-name=shard -o name | wc -l"
  echo "    如果上面也 ≠ 6, 看 pod label 改 stable-service.yaml:"
  echo "    kubectl get pod -n ${NS} redis-cluster-shard-*-0 -o jsonpath='{.metadata.labels}' | python3 -m json.tool"
fi

# ===== 验证命令 =====
echo ""
echo "------- 一键验证 -------"
echo ""
echo "  集群内:"
echo "    POD=\$(kubectl get pod -n ${NS} -l app.kubernetes.io/instance=redis-cluster -o name | head -1)"
echo "    PASS=\$(kubectl get secret ${SECRET_NAME} -n ${NS} -o jsonpath='{.data.password}' | base64 -d)"
echo "    kubectl exec -n ${NS} \${POD#pod/} -c redis -- redis-cli -a \"\$PASS\" --no-auth-warning cluster info | head"
