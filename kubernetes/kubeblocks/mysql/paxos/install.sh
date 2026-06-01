#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/mysql/paxos/install.sh
# 部署 KubeBlocks MySQL Paxos 集群 (apecloud-mysql / WeSQL, 3 节点多数派).
#
# 与 semisync/ 的区别:
#   - componentDef = apecloud-mysql (Paxos), 非社区 mysql-8.0
#   - cluster 名 = mysql-paxos, 与 semisync 的 mysql-cluster 错开, 可并存
#   - 多一步: 检查并启用 apecloud-mysql addon
#
# 用法:
#   bash install.sh                           # 默认 ns=test, 密码=mysql123
#   bash install.sh --ns prod --pass 'Xxx'
#   bash install.sh --wait                    # 等 cluster Running
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false
SECRET_NAME="mysql-paxos-password"
FIXED_PASS="${MYSQL_PASS:-mysql123}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)   NS="$2"; shift 2 ;;
    --wait) WAIT=true; shift ;;
    --pass) FIXED_PASS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 前置 ----------
if ! kubectl get crd clusters.apps.kubeblocks.io &>/dev/null; then
  echo "ERROR: KubeBlocks operator 未安装, 先跑 bash ../../install.sh"
  exit 1
fi

# 检查 apecloud-mysql addon
echo "检查 apecloud-mysql addon..."
ADDON_PHASE=$(kubectl get addons.extensions.kubeblocks.io apecloud-mysql \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)

if [ -z "$ADDON_PHASE" ]; then
  echo "  ✗ apecloud-mysql addon 未找到"
  echo "  请确认 KubeBlocks 版本支持 apecloud-mysql, 或手动安装:"
  echo "    kbcli addon list | grep apecloud-mysql"
  echo "    kbcli addon install apecloud-mysql"
  exit 1
fi

if [ "$ADDON_PHASE" != "Enabled" ]; then
  echo "  当前 phase=${ADDON_PHASE}, 尝试启用..."
  if command -v kbcli &>/dev/null; then
    kbcli addon enable apecloud-mysql || {
      echo "  ✗ kbcli addon enable 失败"
      exit 1
    }
  else
    kubectl patch addons.extensions.kubeblocks.io apecloud-mysql \
      --type=merge -p '{"spec":{"install":{"enabled":true}}}' || {
      echo "  ✗ patch addon 失败, 请装 kbcli 后重试"
      exit 1
    }
  fi
  # 等 addon Enabled
  for i in $(seq 1 30); do
    P=$(kubectl get addons.extensions.kubeblocks.io apecloud-mysql \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/30] addon phase=${P}"
    [ "$P" = "Enabled" ] && break
    sleep 5
  done
fi
echo "  ✓ apecloud-mysql addon 已启用"
echo ""

# 检查 componentDef
if ! kubectl get componentdefinition.apps.kubeblocks.io 2>/dev/null | grep -q apecloud-mysql; then
  echo "WARN: 找不到 apecloud-mysql 的 ComponentDefinition, 可能 addon 还没就绪"
  echo "  kubectl get componentdefinition.apps.kubeblocks.io | grep mysql"
fi

echo "========================================="
echo " KubeBlocks MySQL Paxos 集群安装"
echo "  mode:       apecloud-mysql (WeSQL Paxos)"
echo "  namespace:  ${NS}"
echo "  cluster:    mysql-paxos"
echo "  replicas:   3 (Paxos 多数派)"
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
echo "部署 MySQL Paxos Cluster 到 namespace=${NS}..."
sed "s|namespace: test|namespace: ${NS}|g" "${DIR}/cluster.yaml" | kubectl apply -f -
echo ""

# ---------- 4. 等就绪 ----------
if [ "$WAIT" = true ]; then
  echo "等 cluster.status.phase=Running (3-5 分钟)..."
  for i in $(seq 1 60); do
    STATUS=$(kubectl get cluster.apps.kubeblocks.io mysql-paxos -n "${NS}" \
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
echo "  kubectl get cluster mysql-paxos -n ${NS}"
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=mysql-paxos"
echo ""
echo "连接信息:"
echo "  host:     mysql-paxos-mysql.${NS}.svc"
echo "  port:     3306"
echo "  user:     root"
echo "  password: ${FIXED_PASS}"
echo ""
echo "一键连接 (从集群内 pod):"
echo "  POD=\$(kubectl get pod -n ${NS} -l app.kubernetes.io/instance=mysql-paxos -o name | head -1)"
echo "  kubectl exec -n ${NS} \${POD#pod/} -c mysql -- mysql -uroot -p'${FIXED_PASS}'"
echo ""
echo "查看 leader/follower 角色:"
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=mysql-paxos \\"
echo "    -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.kubeblocks\\.io/role'"
echo ""
echo "查看 Paxos 状态 (集群内):"
echo "  kubectl exec -n ${NS} mysql-paxos-mysql-0 -c mysql -- \\"
echo "    mysql -uroot -p'${FIXED_PASS}' -e 'SELECT * FROM information_schema.wesql_cluster_global;'"
