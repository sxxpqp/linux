#!/bin/bash
# 部署 KubeBlocks Kafka Cluster (KRaft 模式, 3 副本) + 每 broker 独立 NodePort.
#
# NodePort 端口由 K8s 首次分配, 之后稳定 (重启/扩容不变, 仅删 cluster 重装会变).
# 当前端口映射会固化到 ConfigMap/kafka-cluster-endpoints, 业务侧直接读取即可.
#
# 用法:
#   bash install.sh                 # 默认 ns=test
#   bash install.sh --ns prod
#   bash install.sh --wait          # 等到 Running + NodePort 就绪 + 写 ConfigMap (推荐)
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)   NS="$2"; shift 2 ;;
    --wait) WAIT=true; shift ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# //'
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
echo "部署 Kafka Cluster 到 namespace=${NS}..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/cluster.yaml" | kubectl apply -f -
echo ""

# ---------- 2b. 部署稳定内部 ClusterIP Service ----------
# 名字固定 kafka-cluster.${NS}.svc:9092, 业务代码引用这个, 不用关心 KubeBlocks 默认 svc 名带后缀.
# 扩容时新 broker 自动被选入 (selector 用稳定 label), 不用动这个文件.
echo "部署稳定 Service kafka-cluster (集群内业务统一引用)..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/stable-service.yaml" | kubectl apply -f -
echo ""

# ---------- 3. 等就绪 ----------
if [ "$WAIT" = true ]; then
  echo "等 cluster.status.phase=Running (3-5 分钟)..."
  for i in $(seq 1 60); do
    STATUS=$(kubectl get cluster.apps.kubeblocks.io kafka-cluster -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/60] phase=${STATUS:-<empty>}"
    [ "$STATUS" = "Running" ] && break
    [ "$STATUS" = "Failed" ] && { echo "  ✗ Failed"; break; }
    sleep 10
  done
  echo ""

  echo "等 NodePort Service 就绪 (每 broker 一个)..."
  for i in $(seq 1 30); do
    NP_CNT=$(kubectl get svc -n "${NS}" -l app.kubernetes.io/instance=kafka-cluster -o name 2>/dev/null \
      | grep -c advertised-listener || true)
    echo "  [$i/30] advertised-listener svc 数=${NP_CNT}"
    [ "$NP_CNT" -ge 3 ] && break
    sleep 5
  done
  echo ""
fi

# ---------- 4. 抓 NodePort 端口映射, 存到 ConfigMap ----------
# 把当前端口映射固化, 业务侧只读这个 ConfigMap 即可, 重启/扩容自动维护.
ADV_SVCS=$(kubectl get svc -n "${NS}" -l app.kubernetes.io/instance=kafka-cluster -o name 2>/dev/null \
  | grep advertised-listener | sort || true)
NODE_IPS=$(kubectl get node -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}')
EXTERNAL_BOOTSTRAP=""

if [ -n "$ADV_SVCS" ] && [ -n "$NODE_IPS" ]; then
  FIRST_NODE=$(echo "$NODE_IPS" | awk '{print $1}')
  for svc in $ADV_SVCS; do
    NP=$(kubectl get -n "${NS}" "$svc" -o jsonpath='{.spec.ports[?(@.port==9092)].nodePort}' 2>/dev/null)
    [ -z "$NP" ] && NP=$(kubectl get -n "${NS}" "$svc" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    if [ -n "$NP" ]; then
      [ -n "$EXTERNAL_BOOTSTRAP" ] && EXTERNAL_BOOTSTRAP="${EXTERNAL_BOOTSTRAP},"
      EXTERNAL_BOOTSTRAP="${EXTERNAL_BOOTSTRAP}${FIRST_NODE}:${NP}"
    fi
  done

  if [ -n "$EXTERNAL_BOOTSTRAP" ]; then
    echo "保存端口/地址映射到 ConfigMap/kafka-cluster-endpoints ..."
    kubectl create configmap kafka-cluster-endpoints -n "${NS}" \
      --from-literal=bootstrap-internal="kafka-cluster.${NS}.svc:9092" \
      --from-literal=bootstrap-external="${EXTERNAL_BOOTSTRAP}" \
      --from-literal=node-ips="${NODE_IPS}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo ""
  fi
fi

# ---------- 5. 连接信息 ----------
echo ""
echo "==============================================================="
echo " ✓ 连接信息"
echo "==============================================================="
echo ""

# ===== 集群内访问 =====
echo "------- 集群内访问 (K8s pod 内) -------"
echo ""
echo "  ⭐ 业务代码用这个稳定地址 (名字固定, 扩缩容自动维护 endpoints):"
echo "      kafka-cluster.${NS}.svc:9092"
echo ""

# 验证 stable service endpoints 数 = 当前 broker 数
STABLE_EP=$(kubectl get endpoints kafka-cluster -n "${NS}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
EXPECTED_BROKERS=$(kubectl get pod -n "${NS}" -l app.kubernetes.io/instance=kafka-cluster,apps.kubeblocks.io/component-name=kafka-combine -o name 2>/dev/null | wc -l)
echo "  当前 kafka-cluster Service endpoints 数: ${STABLE_EP} (broker pod 数: ${EXPECTED_BROKERS})"

if [ "${STABLE_EP}" -lt "${EXPECTED_BROKERS}" ] && [ "${EXPECTED_BROKERS}" -gt 0 ]; then
  echo ""
  echo "  ⚠ endpoints 少于 broker 数, 可能 label 不匹配. 检查:"
  echo "    kubectl get pod -n ${NS} -l app.kubernetes.io/instance=kafka-cluster,apps.kubeblocks.io/component-name=kafka-combine"
  echo "    kubectl get pod -n ${NS} kafka-cluster-kafka-combine-0 -o jsonpath='{.metadata.labels}'"
fi
echo ""

echo "  (其他可用地址, 一般不需要直接引用:)"
echo "      kafka-cluster-kafka-combine.${NS}.svc:9092           (KubeBlocks 默认 ClusterIP)"
for i in $(seq 0 $((EXPECTED_BROKERS - 1))); do
  [ "${EXPECTED_BROKERS}" -gt 0 ] || break
  echo "      kafka-cluster-kafka-combine-${i}.kafka-cluster-kafka-combine-headless.${NS}.svc:9092  (broker ${i} pod DNS)"
done
echo ""

# ===== 集群外访问 (NodePort) =====
echo "------- 集群外访问 (NodeIP + NodePort) -------"
echo ""
echo "  Node IPs (任一即可, 推荐配多个高可用): ${NODE_IPS:-<取不到>}"
echo ""

if [ -z "$ADV_SVCS" ]; then
  echo "  ⚠ NodePort Service 还没创建, --wait 重跑或检查:"
  echo "      kubectl get svc -n ${NS} | grep advertised-listener"
else
  printf "    %-55s  %-10s\n" "SERVICE" "NodePort"
  for svc in $ADV_SVCS; do
    NAME=${svc#service/}
    NP=$(kubectl get -n "${NS}" "$svc" -o jsonpath='{.spec.ports[?(@.port==9092)].nodePort}' 2>/dev/null)
    [ -z "$NP" ] && NP=$(kubectl get -n "${NS}" "$svc" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    printf "    %-55s  %-10s\n" "${NAME}" "${NP:-—}"
  done
  echo ""
  echo "  ⭐ 业务客户端 bootstrap.servers (任一 NodeIP + 全部 NodePort):"
  echo "      ${EXTERNAL_BOOTSTRAP}"
  echo ""
  echo "  💾 已固化到 ConfigMap/kafka-cluster-endpoints (重启/扩容自动维护):"
  echo "      集群内:  kubectl get cm kafka-cluster-endpoints -n ${NS} -o jsonpath='{.data.bootstrap-internal}'; echo"
  echo "      集群外:  kubectl get cm kafka-cluster-endpoints -n ${NS} -o jsonpath='{.data.bootstrap-external}'; echo"
fi
echo ""

# ===== 端口稳定性说明 =====
echo "------- 端口稳定性说明 -------"
echo ""
echo "  ✓ Pod 重启 / OOM 恢复 / 扩容 → NodePort 不变"
echo "  ✓ 扩容新增 broker → 老 NodePort 不变, 新 broker 多 N 个新端口"
echo "  ✗ 删 cluster 重装 → K8s 重新分配 NodePort (扩容后再跑本脚本会自动更新 ConfigMap)"
echo ""

# ===== 验证命令 =====
echo "------- 验证命令 -------"
echo ""
echo "  # 集群内 - 创建 topic"
echo "  kubectl exec -n ${NS} kafka-cluster-kafka-combine-0 -c kafka -- \\"
echo "    /opt/kafka/bin/kafka-topics.sh --create --topic test \\"
echo "    --bootstrap-server localhost:9092 --partitions 3 --replication-factor 2"
echo ""
if [ -n "$EXTERNAL_BOOTSTRAP" ]; then
  echo "  # 集群外 - list topics (需本机装 kafka 客户端)"
  echo "  kafka-topics.sh --bootstrap-server ${EXTERNAL_BOOTSTRAP} --list"
  echo ""
fi

echo "------- Kubectl 快捷命令 -------"
echo ""
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=kafka-cluster"
echo "  kubectl get svc -n ${NS} -l app.kubernetes.io/instance=kafka-cluster"
echo "  kubectl get cm kafka-cluster-endpoints -n ${NS} -o yaml"
echo "  kubectl get cluster.apps.kubeblocks.io kafka-cluster -n ${NS} -o wide"
