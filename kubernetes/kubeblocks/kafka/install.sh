#!/bin/bash
# 部署 KubeBlocks Kafka Cluster (KRaft 模式, 3 副本).
#
# 用法:
#   bash install.sh                 # 默认 ns=test
#   bash install.sh --ns prod
#   bash install.sh --wait          # 等到 Running
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
fi

# ---------- 4. 连接信息 ----------
echo ""
echo "==============================================================="
echo " ✓ 连接信息"
echo "==============================================================="
echo ""

# 集群内 bootstrap 地址
BOOTSTRAP="kafka-cluster-kafka-combine-0.kafka-cluster-kafka-combine-headless.${NS}.svc:9092"
echo "------- 集群内访问 -------"
echo ""
echo "  Bootstrap (任一 broker):"
echo "    ${BOOTSTRAP}"
echo ""
echo "  全部 broker:"
for i in $(seq 0 2); do
  echo "    kafka-cluster-kafka-combine-${i}.kafka-cluster-kafka-combine-headless.${NS}.svc:9092"
done
echo ""

echo "------- 验证命令 -------"
echo ""
echo "  # 创建 topic"
echo "  kubectl exec -n ${NS} kafka-cluster-kafka-combine-0 -c kafka -- \\"
echo "    /opt/kafka/bin/kafka-topics.sh --create --topic test \\"
echo "    --bootstrap-server localhost:9092 --partitions 3 --replication-factor 2"
echo ""
echo "  # 生产者"
echo "  kubectl exec -n ${NS} kafka-cluster-kafka-combine-0 -c kafka -- \\"
echo "    /opt/kafka/bin/kafka-console-producer.sh --topic test \\"
echo "    --bootstrap-server localhost:9092"
echo ""
echo "  # 消费者"
echo "  kubectl exec -n ${NS} kafka-cluster-kafka-combine-1 -c kafka -- \\"
echo "    /opt/kafka/bin/kafka-console-consumer.sh --topic test \\"
echo "    --bootstrap-server localhost:9092 --from-beginning"
echo ""

echo "------- Kubectl 快捷命令 -------"
echo ""
echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=kafka-cluster"
echo "  kubectl get svc -n ${NS} -l app.kubernetes.io/instance=kafka-cluster"
echo "  kubectl get cluster.apps.kubeblocks.io kafka-cluster -n ${NS} -o wide"
