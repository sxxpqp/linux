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

  # 修 label: 让 kafka-cluster Service selector 匹配 pod
  echo "修复 stable service label 匹配..."
  kubectl label pod -n "${NS}" \
    -l app.kubernetes.io/instance=kafka-cluster,apps.kubeblocks.io/component-name=kafka-combine \
    app.kubernetes.io/name=kafka --overwrite 2>/dev/null || true
  sleep 3
  echo ""
fi

# ---------- 4. 抓 NodePort 端口映射, 存到 ConfigMap ----------
ADV_SVCS=$(kubectl get svc -n "${NS}" -l app.kubernetes.io/instance=kafka-cluster -o name 2>/dev/null \
  | grep advertised-listener | sort || true)
NODE_IPS=$(kubectl get node -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{" "}{end}')
EXTERNAL_BOOTSTRAP=""
INTERNAL_BOOTSTRAP="kafka-cluster-kafka-combine-headless.${NS}.svc:9094"

if [ -n "$ADV_SVCS" ] && [ -n "$NODE_IPS" ]; then
  for svc in $ADV_SVCS; do
    NAME=${svc#service/}
    NP=$(kubectl get -n "${NS}" "$svc" -o jsonpath='{.spec.ports[?(@.port==9092)].nodePort}' 2>/dev/null)
    [ -z "$NP" ] && NP=$(kubectl get -n "${NS}" "$svc" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)

    # 找到该 svc 后端 pod 所在的节点 IP
    POD_IP=$(kubectl get endpoints -n "${NS}" "${NAME}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | awk '{print $1}')
    if [ -n "$POD_IP" ]; then
      POD_NODE=$(kubectl get pod -n "${NS}" -o wide --field-selector status.podIP="${POD_IP}" \
        -o jsonpath='{.items[*].status.hostIP}' 2>/dev/null)
      [ -z "$POD_NODE" ] && POD_NODE=$(echo "$NODE_IPS" | awk '{print $1}')
    else
      POD_NODE=$(echo "$NODE_IPS" | awk '{print $1}')
    fi

    if [ -n "$NP" ] && [ -n "$POD_NODE" ]; then
      [ -n "$EXTERNAL_BOOTSTRAP" ] && EXTERNAL_BOOTSTRAP="${EXTERNAL_BOOTSTRAP},"
      EXTERNAL_BOOTSTRAP="${EXTERNAL_BOOTSTRAP}${POD_NODE}:${NP}"
    fi
  done

  if [ -n "$EXTERNAL_BOOTSTRAP" ]; then
    echo "保存端口/地址映射到 ConfigMap/kafka-cluster-endpoints ..."
    kubectl create configmap kafka-cluster-endpoints -n "${NS}" \
      --from-literal=bootstrap-internal="${INTERNAL_BOOTSTRAP}" \
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

STABLE_EP=$(kubectl get endpoints kafka-cluster -n "${NS}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
EXPECTED_BROKERS=$(kubectl get pod -n "${NS}" -l app.kubernetes.io/instance=kafka-cluster,apps.kubeblocks.io/component-name=kafka-combine -o name 2>/dev/null | wc -l)

if [ "${STABLE_EP}" -ge "${EXPECTED_BROKERS}" ] && [ "${EXPECTED_BROKERS}" -gt 0 ]; then
  echo "  ✅ 集群内 (ClusterIP, 自动负载均衡):"
  echo "      kafka-cluster.${NS}.svc:9092"
  echo ""
  echo "      扩容/重启后 label 自动维护, endpoints 自动更新"
else
  echo "  ⚠  ClusterIP Service label 未匹配, 直接使用 headless 地址:"
  echo "      ${INTERNAL_BOOTSTRAP}"
  echo ""
  echo "      修复命令:"
  echo "      kubectl label pod -n ${NS} -l app.kubernetes.io/instance=kafka-cluster,apps.kubeblocks.io/component-name=kafka-combine app.kubernetes.io/name=kafka --overwrite"
fi
echo ""

echo "  每个 broker 的 pod DNS (直连, 不等负载均衡):"
for i in $(seq 0 $((EXPECTED_BROKERS - 1))); do
  [ "${EXPECTED_BROKERS}" -gt 0 ] || break
  echo "      kafka-cluster-kafka-combine-${i}.kafka-cluster-kafka-combine-headless.${NS}.svc:9094"
done
echo ""

# ===== 集群外访问 (NodePort) =====
echo "------- 集群外访问 (NodeIP + NodePort) -------"
echo ""
echo "  可用 Node IPs: ${NODE_IPS:-<取不到>}"
echo ""

if [ -z "$ADV_SVCS" ]; then
  echo "  ⚠ NodePort Service 还没创建, --wait 重跑"
else
  printf "    %-55s  NodePort\n" "SERVICE"
  for svc in $ADV_SVCS; do
    NAME=${svc#service/}
    NP=$(kubectl get -n "${NS}" "$svc" -o jsonpath='{.spec.ports[?(@.port==9092)].nodePort}' 2>/dev/null)
    [ -z "$NP" ] && NP=$(kubectl get -n "${NS}" "$svc" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
    printf "    %-55s %s\n" "${NAME}" "${NP:-—}"
  done
  echo ""

  echo "  ⭐ bootstrap.servers (用可达的 NodeIP):"
  echo "      ${EXTERNAL_BOOTSTRAP}"
  echo ""
  if [ -n "${NODE_IPS}" ]; then
    echo "  💡 如果某个 NodeIP 不通 (如 128), 去掉该 IP 的地址, 保留通的部分即可."
  fi
  echo ""
  echo "  💾 固化到 ConfigMap/kafka-cluster-endpoints:"
  echo "      集群内:  kubectl get cm kafka-cluster-endpoints -n ${NS} -o jsonpath='{.data.bootstrap-internal}'; echo"
  echo "      集群外:  kubectl get cm kafka-cluster-endpoints -n ${NS} -o jsonpath='{.data.bootstrap-external}'; echo"
fi
echo ""

# ===== 端口稳定性说明 =====
echo "------- 端口稳定性说明 -------"
echo ""
echo "  ✓ Pod 重启 / OOM 恢复 / 扩容 → NodePort 不变"
echo "  ✓ 扩容新增 broker → 老 NodePort 不变, 新 broker 多 N 个新端口"
echo "  ✗ 删 cluster 重装 → K8s 重新分配 NodePort"
echo ""

# ===== 验证命令 =====
echo "------- 验证命令 -------"
echo ""
echo "  # 集群内 - 创建 topic (用 headless 9094)"
echo "  kubectl exec -n ${NS} kafka-cluster-kafka-combine-0 -c kafka -- \\"
echo "    /opt/kafka/bin/kafka-topics.sh --create --topic test \\"
echo "    --bootstrap-server ${INTERNAL_BOOTSTRAP} \\"
echo "    --partitions 3 --replication-factor 2"
echo ""
if [ -n "$EXTERNAL_BOOTSTRAP" ]; then
  echo "  # 集群外 - list topics (需本机装 kafka 客户端)"
  echo "  kafka-topics.sh --bootstrap-server ${EXTERNAL_BOOTSTRAP} --list"
  echo ""
fi

echo "------- 端口映射关系 -------"
echo ""
echo "  Kafka Listener → Service 映射:"
echo "    CLIENT (9092)   → advertised-listener svc → NodePort (外部) / kafka-cluster svc (内部)"
echo "    INTERNAL (9094) → headless svc (pod 间副本同步)"
echo "    CONTROLLER (9093) → headless svc (KRaft 控制器通信)"
echo ""

echo "------- Kubectl 快捷命令 -------"
echo ""
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=kafka-cluster"
echo "  kubectl get svc -n ${NS} -l app.kubernetes.io/instance=kafka-cluster"
echo "  kubectl get cm kafka-cluster-endpoints -n ${NS} -o yaml"
echo "  kubectl get cluster.apps.kubeblocks.io kafka-cluster -n ${NS} -o wide"
