#!/bin/bash
# 安装 local-path-provisioner (测试/开发环境 StorageClass).
#
# 注意: 数据存在节点本地磁盘, 节点故障数据丢失, 不适合生产.
# 生产存储推荐 longhorn/ 或 csi-driver-nfs/.
#
# 步骤:
#   1. apply local-path-storage.yaml (Namespace + RBAC + Deployment + StorageClass)
#   2. 等 provisioner pod Running
#   3. (可选) 设为默认 StorageClass
#
# 用法:
#   bash install.sh                  # 安装, 不设为默认
#   bash install.sh --set-default    # 安装并设为默认 StorageClass
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="local-path-storage"
SC_NAME="local-path"
SET_DEFAULT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --set-default) SET_DEFAULT=true; shift ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

echo "========================================="
echo " local-path-provisioner 安装"
echo "  namespace:    ${NS}"
echo "  storageclass: ${SC_NAME}"
echo "  set-default:  ${SET_DEFAULT}"
echo "========================================="
echo ""

command -v kubectl >/dev/null || { echo "ERROR: kubectl 未安装"; exit 1; }

# ---------- 1. apply 清单 ----------
echo "[1/2] 部署 local-path-provisioner ..."
kubectl apply -f "${DIR}/local-path-storage.yaml"
echo ""

# ---------- 2. 等 pod Running ----------
echo "[2/2] 等 provisioner pod Running ..."
kubectl -n "${NS}" rollout status deploy/local-path-provisioner --timeout=3m
echo ""

# ---------- 3. 设为默认 (可选) ----------
if [ "$SET_DEFAULT" = true ]; then
  echo "设 ${SC_NAME} 为默认 StorageClass ..."
  kubectl patch storageclass "${SC_NAME}" \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
  echo "  ✓ 已设为默认"
  echo ""
fi

echo "==============================================================="
echo " ✓ local-path-provisioner 装完"
echo "==============================================================="
echo ""
echo "StorageClass:"
kubectl get storageclass
echo ""
echo "Provisioner pod:"
kubectl -n "${NS}" get pod
echo ""
echo "数据默认存放路径: /opt/local-path-provisioner/<pvc-name>/"
echo "改路径: kubectl -n ${NS} edit cm local-path-config"
echo ""
echo "验证:"
echo "  kubectl apply -f - <<'EOF'"
echo "  apiVersion: v1"
echo "  kind: PersistentVolumeClaim"
echo "  metadata:"
echo "    name: test-pvc"
echo "  spec:"
echo "    accessModes: [ReadWriteOnce]"
echo "    storageClassName: ${SC_NAME}"
echo "    resources:"
echo "      requests:"
echo "        storage: 128Mi"
echo "  EOF"
echo "  kubectl get pvc test-pvc"
