#!/bin/bash
# 卸载 local-path-provisioner.
#
# 注意:
#   - 删除 Namespace local-path-storage 会同时删除 Deployment / RBAC / ConfigMap
#   - StorageClass local-path 也会被删除
#   - 默认不删除已有 PVC/PV, 脚本会列出并询问是否删除
#   - PV 里的数据 (节点本地目录) 不会自动清理, 需手动删除
#
# 用法:
#   bash uninstall.sh              # 交互询问是否删除 PVC
#   bash uninstall.sh --delete-pvc # 直接删除所有 local-path PVC (不询问)
#   bash uninstall.sh --keep-pvc   # 保留 PVC, 不询问
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="local-path-storage"
SC_NAME="local-path"
DELETE_PVC=""   # ""=交互  "yes"=直接删  "no"=保留

while [ $# -gt 0 ]; do
  case "$1" in
    --delete-pvc) DELETE_PVC="yes"; shift ;;
    --keep-pvc)   DELETE_PVC="no";  shift ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

echo "========================================="
echo " local-path-provisioner 卸载"
echo "  namespace:    ${NS}"
echo "  storageclass: ${SC_NAME}"
echo "========================================="
echo ""

command -v kubectl >/dev/null || { echo "ERROR: kubectl 未安装"; exit 1; }

# ---------- 检查 PVC ----------
echo "查找使用 ${SC_NAME} 的 PVC ..."
PVC_LIST=$(kubectl get pvc -A \
  --field-selector=spec.storageClassName="${SC_NAME}" \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,CAPACITY:.spec.resources.requests.storage' \
  2>/dev/null || true)

# field-selector 对 storageClassName 支持不稳定, 用 grep 兜底
if [ -z "$PVC_LIST" ] || ! echo "$PVC_LIST" | grep -q "${SC_NAME}" 2>/dev/null; then
  PVC_LIST=$(kubectl get pvc -A -o wide 2>/dev/null | awk 'NR==1 || $7=="'"${SC_NAME}"'"' || true)
fi

PVC_COUNT=$(echo "$PVC_LIST" | tail -n +2 | grep -c . || true)

if [ "$PVC_COUNT" -gt 0 ]; then
  echo ""
  echo "发现 ${PVC_COUNT} 个 PVC 使用 StorageClass ${SC_NAME}:"
  echo "$PVC_LIST"
  echo ""

  if [ "$DELETE_PVC" = "" ]; then
    read -r -p "是否删除这些 PVC? 删除后数据无法恢复! [y/N] " CONFIRM
    case "$CONFIRM" in
      y|Y|yes|YES) DELETE_PVC="yes" ;;
      *)            DELETE_PVC="no"  ;;
    esac
    echo ""
  fi

  if [ "$DELETE_PVC" = "yes" ]; then
    echo "删除所有 ${SC_NAME} PVC ..."
    kubectl get pvc -A -o json \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data['items']:
    sc = item.get('spec', {}).get('storageClassName', '')
    if sc == '${SC_NAME}':
        ns  = item['metadata']['namespace']
        name = item['metadata']['name']
        print(ns + ' ' + name)
" | while read -r ns name; do
        echo "  删除 PVC: ${ns}/${name}"
        kubectl delete pvc -n "$ns" "$name" --ignore-not-found
      done
    echo "  ✓ PVC 删除完成"
    echo ""
    echo "  ⚠ 节点本地数据目录未自动清理, 需手动删除:"
    echo "    ls /opt/local-path-provisioner/"
    echo "    rm -rf /opt/local-path-provisioner/<pvc-name>"
  else
    echo "  保留 PVC. provisioner 卸载后新 PVC 将一直 Pending, 已有 PVC 数据不受影响."
    echo "  需要时手动删除: kubectl delete pvc -n <ns> <name>"
  fi
  echo ""
else
  echo "  未发现使用 ${SC_NAME} 的 PVC"
  echo ""
fi

# ---------- 删除 provisioner ----------
echo "删除 local-path-provisioner 所有资源 ..."
kubectl delete -f "${DIR}/local-path-storage.yaml" --ignore-not-found
echo ""

echo "==============================================================="
echo " ✓ local-path-provisioner 已卸载"
echo "==============================================================="
