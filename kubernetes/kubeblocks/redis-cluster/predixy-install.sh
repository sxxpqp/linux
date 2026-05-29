#!/bin/bash
# 部署 Predixy 作为 Redis Cluster 的外部入口代理.
# 对外部客户端 (Navicat 等) 表现为单实例 Redis, 内部仍走 cluster mode 路由.
#
# 前置条件:
#   1. KubeBlocks Redis Cluster 已部署且 Running
#   2. Secret/redis-cluster-password 存在 (install.sh 跑完会自动同步)
#
# 用法:
#   bash predixy-install.sh                 # 部署到 test ns
#   bash predixy-install.sh --ns prod
#   bash predixy-install.sh --nodeport 32379  # 改 NodePort
#   bash predixy-install.sh --image my-registry/predixy:1.0.5  # 改镜像
#   bash predixy-install.sh --wait          # 等就绪 + 跑连通性测试
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
      sed -n '2,12p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 前置检查 ----------
echo "[1/5] 前置检查..."
if ! kubectl get secret redis-cluster-password -n "${NS}" &>/dev/null; then
  echo "  ERROR: Secret/redis-cluster-password 不存在于 ns=${NS}"
  echo "  先跑: bash install.sh --wait"
  exit 1
fi
echo "  ✓ Secret/redis-cluster-password 存在"

# 检查 Redis Cluster headless services
for shard in $(kubectl get svc -n "${NS}" -o name 2>/dev/null | grep redis-cluster-shard | grep headless); do
  echo "  ✓ ${shard#service/}"
done
HEADLESS_CNT=$(kubectl get svc -n "${NS}" -l app.kubernetes.io/instance=redis-cluster -o name 2>/dev/null | grep -c headless || true)
if [ "$HEADLESS_CNT" -lt 3 ]; then
  echo "  ERROR: 没找到 3 个 Redis Cluster shard headless service (找到 ${HEADLESS_CNT})"
  exit 1
fi
echo ""

# ---------- 渲染 yaml ----------
echo "[2/5] 渲染 predixy.yaml..."
TMP_YAML=$(mktemp)
sed "s|namespace: test|namespace: ${NS}|g" "${DIR}/predixy.yaml" > "${TMP_YAML}"

# 改 NodePort
if [ -n "${NODEPORT}" ]; then
  sed -i "s|nodePort: 31379|nodePort: ${NODEPORT}|g" "${TMP_YAML}"
  echo "  → NodePort 改为 ${NODEPORT}"
fi

# 改镜像
if [ -n "${IMAGE}" ]; then
  sed -i "s|image: haandol/predixy:latest|image: ${IMAGE}|g" "${TMP_YAML}"
  echo "  → 镜像改为 ${IMAGE}"
fi
echo ""

# ---------- 部署 ----------
echo "[3/5] 应用 predixy 资源..."
kubectl apply -f "${TMP_YAML}"
rm -f "${TMP_YAML}"
echo ""

# ---------- 等就绪 ----------
echo "[4/5] 等 predixy pod 就绪..."
if [ "$WAIT" = true ]; then
  kubectl -n "${NS}" rollout status deploy/predixy --timeout=180s || {
    echo "  ✗ Predixy pod 没起来"
    kubectl -n "${NS}" get pod -l app=predixy
    kubectl -n "${NS}" logs -l app=predixy --tail=30 --all-containers
    exit 1
  }
else
  echo "  (跳过等待, 加 --wait 阻塞到就绪)"
fi
echo ""

# ---------- 连通性测试 ----------
echo "[5/5] 测试 Predixy 转发..."
if [ "$WAIT" = true ]; then
  PASS=$(kubectl get secret redis-cluster-password -n "${NS}" -o jsonpath='{.data.password}' | base64 -d)

  # 集群内通过 Predixy ClusterIP 测试
  kubectl run -n "${NS}" predixy-test --rm -i --restart=Never --image=redis:7-alpine -- sh -c "
    echo '--- PING ---'
    redis-cli -h predixy -p 6379 -a '$PASS' ping
    echo '--- SET / GET (走 cluster slot 路由) ---'
    redis-cli -h predixy -p 6379 -a '$PASS' set predixy-test-key1 hello
    redis-cli -h predixy -p 6379 -a '$PASS' set predixy-test-key2 world
    redis-cli -h predixy -p 6379 -a '$PASS' get predixy-test-key1
    redis-cli -h predixy -p 6379 -a '$PASS' get predixy-test-key2
    echo '--- INFO (Predixy 自己的信息) ---'
    redis-cli -h predixy -p 6379 -a '$PASS' info server | head -10
  " 2>&1 | grep -v "^Warning:" || true
fi
echo ""

# ---------- 连接信息汇总 ----------
echo "================================================================="
echo " ✓ Predixy 已部署"
echo "================================================================="
echo ""

ACTUAL_PASS=$(kubectl get secret redis-cluster-password -n "${NS}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
NP=$(kubectl get svc predixy-nodeport -n "${NS}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
NODE_IPS=$(kubectl get node -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}')

echo "------- 集群内访问 (业务 pod) -------"
echo "  Host:     predixy.${NS}.svc (或同 ns 直接: predixy)"
echo "  Port:     6379"
echo "  Password: ${ACTUAL_PASS}"
echo "  Mode:     Standalone (不是 Cluster!)"
echo ""

echo "------- 集群外访问 (Navicat / RedisInsight / DBeaver) -------"
echo "  Host:     任一 Node IP -> ${NODE_IPS}"
echo "  Port:     ${NP}"
echo "  Password: ${ACTUAL_PASS}"
echo "  Mode:     Standalone (不是 Cluster!)"
echo ""

echo "------- 验证命令 -------"
echo "  # 本地有 redis-cli:"
echo "  redis-cli -h $(echo $NODE_IPS | awk '{print $1}') -p ${NP} -a '${ACTUAL_PASS}' ping"
echo "  redis-cli -h $(echo $NODE_IPS | awk '{print $1}') -p ${NP} -a '${ACTUAL_PASS}' set hi navicat"
echo "  redis-cli -h $(echo $NODE_IPS | awk '{print $1}') -p ${NP} -a '${ACTUAL_PASS}' get hi"
echo ""

echo "------- 关键点 -------"
echo "  - Predixy 把 cluster 包成 'standalone 外观', 客户端按单实例 Redis 配置即可"
echo "  - 内部仍是 cluster 模式路由, 跟直接用 redis-cli -c 效果一样"
echo "  - 99% 的 redis 命令都支持 (含事务/lua/pub-sub), 个别极少用的不支持"
echo "  - 2 副本 HA, 任一 pod 挂了不影响 (NodePort kube-proxy 自动路由到健康 pod)"
