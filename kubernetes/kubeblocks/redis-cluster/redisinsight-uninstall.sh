#!/bin/bash
# 卸载 RedisInsight.
# 用法:
#   bash redisinsight-uninstall.sh
#   bash redisinsight-uninstall.sh --ns prod
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

echo "卸载 RedisInsight (ns=${NS})..."
kubectl delete deploy/redisinsight svc/redisinsight -n "${NS}" --ignore-not-found
echo "✓ 完成 (Redis Cluster 不受影响)"
