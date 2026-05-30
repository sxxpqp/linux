#!/bin/bash
# 卸载 local-path-provisioner.
#
# 注意:
#   - 删除 Namespace local-path-storage 会同时删除 Deployment / RBAC / ConfigMap
#   - StorageClass local-path 也会被删除
#   - 已绑定的 PVC/PV 不会自动删除, 但 provisioner 没了, 新 PVC 将一直 Pending
#   - 已有 PV 里的数据 (节点本地目录) 不受影响, 需手动清理
#
# 用法:
#   bash uninstall.sh
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="local-path-storage"
SC_NAME="local-path"

echo "========================================="
echo " local-path-provisioner 卸载"
echo "  namespace:    ${NS}"
echo "  storageclass: ${SC_NAME}"
echo "========================================="
echo ""

command -v kubectl >/dev/null || { echo "ERROR: kubectl 未安装"; exit 1; }

# ---------- 删除清单里的所有资源 ----------
echo "删除 local-path-provisioner 所有资源 ..."
kubectl delete -f "${DIR}/local-path-storage.yaml" --ignore-not-found
echo ""

# ---------- 确认 ----------
echo "==============================================================="
echo " ✓ local-path-provisioner 已卸载"
echo "==============================================================="
echo ""
echo "残留检查:"
echo "  PVC (未绑定 provisioner 的 PVC 会卡 Pending):"
echo "    kubectl get pvc -A | grep ${SC_NAME}"
echo ""
echo "  节点本地数据目录 (手动清理):"
echo "    ls /opt/local-path-provisioner/"
