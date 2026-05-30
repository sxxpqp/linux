#!/bin/bash
# 部署 KubeBlocks MySQL 集群 (1 主 + 2 从, 共 3 节点).
#
# 用法:
#   bash install.sh                           # 默认 ns=test, 密码=mysql123
#   bash install.sh --ns prod --pass 'Xxx'
#   bash install.sh --wait                    # 等 cluster Running
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false
SECRET_NAME="mysql-cluster-password"
FIXED_PASS="${MYSQL_PASS:-mysql123}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)   NS="$2"; shift 2 ;;
    --wait) WAIT=true; shift ;;
    --pass) FIXED_PASS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 前置 ----------
if ! kubectl get crd clusters.apps.kubeblocks.io &>/dev/null; then
  echo "ERROR: KubeBlocks operator 未安装, 先跑 bash ../install.sh"
  exit 1
fi

echo "========================================="
echo " KubeBlocks MySQL 集群安装"
echo "  namespace:  ${NS}"
echo "  replicas:   3 (1 主 + 2 从)"
echo "  secret:     ${SECRET_NAME}"
echo "========================================="
echo ""

# ---------- 1. namespace ----------
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# ---------- 2. 预创建 Secret ----------
echo "预创建 Secret/${SECRET_NAME} (username=root, password=${FIXED_PASS})..."
kubectl create secret generic "${SECRET_NAME}" -n "${NS}" \
  --from-literal=username=root \
  --from-literal=password="${FIXED_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ---------- 3. 部署 Cluster ----------
echo "部署 MySQL Cluster 到 namespace=${NS}..."
sed "s|namespace: test|namespace: ${NS}|g" "${DIR}/cluster.yaml" | kubectl apply -f -
echo ""

# ---------- 4. 等就绪 ----------
if [ "$WAIT" = true ]; then
  echo "等 cluster.status.phase=Running (3-5 分钟)..."
  for i in $(seq 1 60); do
    STATUS=$(kubectl get cluster.apps.kubeblocks.io mysql-cluster -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/60] phase=${STATUS:-<empty>}"
    [ "$STATUS" = "Running" ] && break
    [ "$STATUS" = "Failed"  ] && { echo "  ✗ Failed"; break; }
    sleep 10
  done
  echo ""
fi

echo "==============================================================="
echo " ✓ 部署完成"
echo "==============================================================="
echo ""
echo "查看集群状态:"
echo "  kubectl get cluster mysql-cluster -n ${NS}"
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=mysql-cluster"
echo ""
echo "连接信息:"
echo "  host:     mysql-cluster-mysql.${NS}.svc"
echo "  port:     3306"
echo "  user:     root"
echo "  password: ${FIXED_PASS}"
echo ""
echo "一键连接 (从集群内 pod):"
echo "  POD=\$(kubectl get pod -n ${NS} -l app.kubernetes.io/instance=mysql-cluster -o name | head -1)"
echo "  kubectl exec -n ${NS} \${POD#pod/} -c mysql -- mysql -uroot -p'${FIXED_PASS}'"
echo ""
echo "查看主从角色:"
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=mysql-cluster \\"
echo "    -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.kubeblocks\\.io/role'"
