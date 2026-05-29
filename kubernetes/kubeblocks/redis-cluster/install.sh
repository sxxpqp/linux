#!/bin/bash
# 部署 KubeBlocks Redis Sharding Cluster (3 shard × 2 副本 = 6 pod).
# 每个 pod 自动创建 NodePort, 外部可用 cluster mode 连接.
#
# 注意 v1.0.2 sharding 模式密码由 KubeBlocks 自动生成 (固定 systemAccounts.secretRef
# 实测不生效), 脚本会在 cluster Ready 后**把实际密码同步到一个固定名字的 Secret**
# 方便取用: redis-cluster-password
#
# 用法:
#   bash install.sh                 # 默认 ns=test
#   bash install.sh --ns prod
#   bash install.sh --wait          # 等到 Running + NodePort 都就绪
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false
ALIAS_SECRET="redis-cluster-password"  # 同步的固定名 Secret

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)   NS="$2"; shift 2 ;;
    --wait) WAIT=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# //'
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

# ---------- 2. 部署 Cluster ----------
echo "部署 Redis Cluster 到 namespace=${NS}..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/cluster.yaml" | kubectl apply -f -
echo ""

# ---------- 2b. 部署稳定 Service (跨 shard, 名字固定) ----------
echo "部署稳定 Service redis-cluster (业务代码引用这个, 不受 shard 后缀变化影响)..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/stable-service.yaml" | kubectl apply -f -
echo ""

# ---------- 3. 等就绪 ----------
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

  echo "等 NodePort Service 就绪 (每 pod 一个, 共 6 个)..."
  for i in $(seq 1 30); do
    NP_CNT=$(kubectl get svc -n "${NS}" -l app.kubernetes.io/instance=redis-cluster -o name 2>/dev/null \
      | grep -c advertised || true)
    echo "  [$i/30] advertised svc 数=${NP_CNT}"
    [ "$NP_CNT" -ge 6 ] && break
    sleep 5
  done
  echo ""
fi

# ---------- 4. 同步实际密码到固定 Secret ----------
# sharding 模式 KubeBlocks 给每个 shard 一个 secret, 内容相同
# 复制到 ${ALIAS_SECRET} 便于业务侧统一引用
ACTUAL_PASS=""
SRC_SEC=$(kubectl get secret -n "${NS}" -l app.kubernetes.io/instance=redis-cluster -o name 2>/dev/null \
  | grep -i 'account-default' | head -1)
if [ -n "$SRC_SEC" ]; then
  ACTUAL_PASS=$(kubectl get -n "${NS}" "$SRC_SEC" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
fi

if [ -n "$ACTUAL_PASS" ]; then
  echo "同步密码到 Secret/${ALIAS_SECRET}..."
  kubectl create secret generic "${ALIAS_SECRET}" -n "${NS}" \
    --from-literal=password="${ACTUAL_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo ""
else
  echo "WARN: 还没取到密码 (cluster 可能没 Ready), --wait 再跑一次或手动同步:"
  echo "  SRC=\$(kubectl get secret -n ${NS} -l app.kubernetes.io/instance=redis-cluster -o name | grep account-default | head -1)"
  echo "  PASS=\$(kubectl get -n ${NS} \$SRC -o jsonpath='{.data.password}' | base64 -d)"
  echo "  kubectl create secret generic ${ALIAS_SECRET} -n ${NS} --from-literal=password=\"\$PASS\""
fi

# ---------- 5. 连接信息汇总 ----------
echo ""
echo "==============================================================="
echo " ✓ 连接信息"
echo "==============================================================="

# ===== 密码 =====
echo ""
echo "------- 密码 -------"
if [ -n "$ACTUAL_PASS" ]; then
  echo "  当前密码:  ${ACTUAL_PASS}"
fi
echo "  随时取用:  kubectl get secret ${ALIAS_SECRET} -n ${NS} -o jsonpath='{.data.password}' | base64 -d; echo"

# ===== 集群内访问 =====
echo ""
echo "------- 集群内访问 (从 K8s pod 内连) -------"
echo ""
echo "  ⭐ 业务代码用这个稳定地址 (跨所有 shard, 名字固定):"
echo "      redis-cluster.${NS}.svc:6379"
echo ""
echo "  (底层是 cluster 级别 Headless Service, 解析到全部 redis pod IP."
echo "   cluster client 拿任一作 seed 自动发现拓扑, shard 后缀变化无感.)"
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

# ===== 外部访问 =====
echo ""
echo "------- 外部访问 (Redis Cluster mode + NodePort) -------"
echo ""

NODE_IPS=$(kubectl get node -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}')
echo "  Node IPs (任选): ${NODE_IPS:-<取不到>}"

echo ""
echo "  每 pod 一个 NodePort (cluster client 用任一即可, 自动跟 MOVED 跳转):"
ADV_SVCS=$(kubectl get svc -n "${NS}" -l app.kubernetes.io/instance=redis-cluster -o name 2>/dev/null | grep advertised || true)
if [ -z "$ADV_SVCS" ]; then
  echo "    (NodePort 还没创建, cluster 没 Ready 或者 services 字段没启用)"
  echo "    检查: kubectl get svc -n ${NS} | grep advertised"
else
  printf "    %-50s  %-8s  %-8s\n" "SERVICE" "REDIS" "BUS"
  for svc in $ADV_SVCS; do
    NAME=${svc#service/}
    NP6379=$(kubectl get -n "${NS}" "$svc" -o jsonpath='{.spec.ports[?(@.port==6379)].nodePort}' 2>/dev/null)
    NP16379=$(kubectl get -n "${NS}" "$svc" -o jsonpath='{.spec.ports[?(@.port==16379)].nodePort}' 2>/dev/null)
    printf "    %-50s  %-8s  %-8s\n" "${NAME}" "${NP6379:-—}" "${NP16379:-—}"
  done
fi

# ===== 验证命令 =====
echo ""
echo "------- 一键验证 -------"
echo ""
FIRST_NODE_IP=$(echo "$NODE_IPS" | awk '{print $1}')
FIRST_NP=""
if [ -n "$ADV_SVCS" ]; then
  FIRST_NP=$(echo "$ADV_SVCS" | head -1 \
    | xargs -I{} kubectl get -n "${NS}" {} -o jsonpath='{.spec.ports[?(@.port==6379)].nodePort}' 2>/dev/null)
fi

echo "  集群内 (任一 redis pod):"
echo "    POD=\$(kubectl get pod -n ${NS} -l apps.kubeblocks.io/cluster-name=redis-cluster -o name | head -1)"
echo "    PASS=\$(kubectl get secret ${ALIAS_SECRET} -n ${NS} -o jsonpath='{.data.password}' | base64 -d)"
echo "    kubectl exec -n ${NS} \${POD#pod/} -- redis-cli -a \"\$PASS\" cluster info | head"
echo ""
if [ -n "$FIRST_NODE_IP" ] && [ -n "$FIRST_NP" ] && [ -n "$ACTUAL_PASS" ]; then
  echo "  集群外 (开发机直连, 需要 redis-cli):"
  echo "    redis-cli -h ${FIRST_NODE_IP} -p ${FIRST_NP} -a '${ACTUAL_PASS}' -c cluster info | head"
  echo "    redis-cli -h ${FIRST_NODE_IP} -p ${FIRST_NP} -a '${ACTUAL_PASS}' -c set foo bar"
  echo "    redis-cli -h ${FIRST_NODE_IP} -p ${FIRST_NP} -a '${ACTUAL_PASS}' -c get foo"
fi
