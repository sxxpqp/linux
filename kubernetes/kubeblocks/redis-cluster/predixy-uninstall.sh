#!/bin/bash
# 卸载 Predixy 代理.
# 用法:
#   bash predixy-uninstall.sh
#   bash predixy-uninstall.sh --ns prod
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
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

echo "卸载 predixy 资源 (ns=${NS})..."
kubectl delete deploy/predixy svc/predixy svc/predixy-nodeport cm/predixy-config \
  -n "${NS}" --ignore-not-found

echo ""
echo "✓ 完成. Redis Cluster 不受影响."
