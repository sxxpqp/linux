#!/bin/bash
# 安装 Kubernetes external-snapshotter (VolumeSnapshot CRD + controller).
# KubeBlocks dataprotection 控制器依赖这个做基于 PVC 快照的备份.
# 不装不影响 Cluster 创建, 但 BackupSchedule 不能用 snapshot 类型,
# 同时 dataprotection controller 会一直刷 "VolumeSnapshot not found" 报错.
#
# 用法:
#   bash install-snapshotter.sh                # 默认内网镜像 (单文件 all-in-one)
#   bash install-snapshotter.sh --public       # 走 GitHub raw (官方原始 yaml 分多文件)
#   bash install-snapshotter.sh --version v8.0.1
set -uo pipefail

VERSION="v8.0.1"
USE_PUBLIC=false

# 内网整合包 (CRD + controller + RBAC 一个 yaml 搞定)
INTERNAL_URL="https://chfs.sxxpqp.top:8443/chfs/shared/k8s/kubeblocks/snapshot.storage.k8s.yaml"

# 公网官方源 (按版本分多个文件)
PUBLIC_BASE="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter"

for ((i=1; i<=$#; i++)); do
  case "${!i}" in
    --version) i=$((i+1)); VERSION="${!i}" ;;
    --public)  USE_PUBLIC=true ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: ${!i}"; exit 1 ;;
  esac
done

echo "========================================="
echo " external-snapshotter 安装"
echo "  source:  $([ "$USE_PUBLIC" = true ] && echo "GitHub $VERSION" || echo "内网镜像")"
echo "========================================="
echo ""

if [ "$USE_PUBLIC" = false ]; then
  # ----- 内网整合包 (一个 yaml 含所有资源) -----
  echo "[1/1] 应用内网整合包: ${INTERNAL_URL}"
  if ! kubectl apply --server-side -f "${INTERNAL_URL}"; then
    echo ""
    echo "ERROR: 内网镜像安装失败. 改用公网:"
    echo "  bash install-snapshotter.sh --public"
    exit 1
  fi
else
  # ----- GitHub 公网 (分多文件) -----
  echo "[1/2] 安装 VolumeSnapshot CRDs..."
  for crd in \
    snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
    snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
    snapshot.storage.k8s.io_volumesnapshots.yaml; do
    echo "  → ${crd}"
    kubectl apply --server-side -f \
      "${PUBLIC_BASE}/${VERSION}/client/config/crd/${crd}"
  done
  echo ""

  echo "[2/2] 安装 snapshot-controller (Deployment + RBAC)..."
  kubectl apply -f \
    "${PUBLIC_BASE}/${VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
  kubectl apply -f \
    "${PUBLIC_BASE}/${VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"
fi

echo ""
echo "等待 snapshot-controller 就绪..."
kubectl -n kube-system rollout status deploy/snapshot-controller --timeout=120s || true

echo ""
echo "========================================="
echo " 安装完成"
echo "========================================="
echo ""
echo "VolumeSnapshot CRD:"
kubectl get crd | grep snapshot.storage.k8s.io || echo "  (没找到, 安装可能失败)"
echo ""
echo "snapshot-controller pod:"
kubectl -n kube-system get pod -l app=snapshot-controller 2>/dev/null \
  || kubectl -n kube-system get pod -l app.kubernetes.io/name=snapshot-controller 2>/dev/null \
  || echo "  (没找到)"
echo ""
echo "下一步: 为 Longhorn 创建 VolumeSnapshotClass"
echo ""
cat <<'YAML'
  cat <<EOF | kubectl apply -f -
  apiVersion: snapshot.storage.k8s.io/v1
  kind: VolumeSnapshotClass
  metadata:
    name: longhorn-snapshot-class
    labels:
      kubeblocks.io/storage-snapshot-class: "true"
  driver: driver.longhorn.io
  deletionPolicy: Delete
  parameters:
    type: snap
  EOF
YAML
