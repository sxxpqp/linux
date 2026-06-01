#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/kafka/kafka-ui-install.sh
# 部署 Kafka UI (Web GUI).
#
# 用法:
#   bash kafka-ui-install.sh                 # 默认 ns=test
#   bash kafka-ui-install.sh --ns prod
#   bash kafka-ui-install.sh --wait          # 等到 Ready + 打印访问地址
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

echo "部署 Kafka UI 到 namespace=${NS}..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/kafka-ui.yaml" | kubectl apply -f -
echo ""

if [ "$WAIT" = true ]; then
  echo "等 kafka-ui Ready..."
  kubectl wait deployment kafka-ui -n "${NS}" --for=condition=available --timeout=2m
  echo ""

  NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  NP=$(kubectl get svc kafka-ui -n "${NS}" -o jsonpath='{.spec.ports[0].nodePort}')
  echo "==============================================================="
  echo " Kafka UI 已就绪"
  echo "==============================================================="
  echo ""
  echo "访问:  http://${NODE_IP}:${NP}"
  echo ""
fi
