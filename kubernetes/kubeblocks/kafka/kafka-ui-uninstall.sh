#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/kafka/kafka-ui-uninstall.sh
# 卸载 Kafka UI (不影响 Kafka Cluster).
#
# 用法:
#   bash kafka-ui-uninstall.sh
#   bash kafka-ui-uninstall.sh --ns prod
set -uo pipefail

NS="test"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns) NS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,5p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
  esac
done

kubectl delete deployment kafka-ui -n "${NS}" --ignore-not-found=true
kubectl delete service kafka-ui -n "${NS}" --ignore-not-found=true
echo "✓ Kafka UI 已卸载"
