#!/bin/bash
# 安装 Kubernetes external-snapshotter (VolumeSnapshot CRD + controller).
# KubeBlocks dataprotection 控制器依赖这个做基于 PVC 快照的备份.
# 不装不影响 Cluster 创建, 但 BackupSchedule 不能用 snapshot 类型.
#
# 用法:
#   bash install-snapshotter.sh                # 默认 v8.0.1
#   bash install-snapshotter.sh --version v6.3.3
set -uo pipefail

VERSION="v8.0.1"
# 镜像源: 公网原始 / 内网镜像 (按需切换)
BASE_URL="https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter"

for ((i=1; i<=$#; i++)); do
  case "${!i}" in
    --version) i=$((i+1)); VERSION="${!i}" ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: ${!i}"; exit 1 ;;
  esac
done

echo "========================================="
echo " external-snapshotter 安装"
echo "  version: ${VERSION}"
echo "========================================="
echo ""

echo "[1/2] 安装 VolumeSnapshot CRDs..."
for crd in \
  snapshot.storage.k8s.io_volumesnapshotclasses.yaml \
  snapshot.storage.k8s.io_volumesnapshotcontents.yaml \
  snapshot.storage.k8s.io_volumesnapshots.yaml; do
  echo "  → ${crd}"
  kubectl apply --server-side -f \
    "${BASE_URL}/${VERSION}/client/config/crd/${crd}"
done
echo ""

echo "[2/2] 安装 snapshot-controller (Deployment + RBAC)..."
kubectl apply -f \
  "${BASE_URL}/${VERSION}/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml"
kubectl apply -f \
  "${BASE_URL}/${VERSION}/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml"

echo ""
echo "等待 snapshot-controller 就绪..."
kubectl -n kube-system rollout status deploy/snapshot-controller --timeout=120s

echo ""
echo "========================================="
echo " 安装完成"
echo "========================================="
echo ""
kubectl get crd | grep snapshot.storage.k8s.io
echo ""
kubectl -n kube-system get pod -l app=snapshot-controller
echo ""
echo "下一步: 为 Longhorn 创建 VolumeSnapshotClass"
echo "  cat <<EOF | kubectl apply -f -"
echo "  apiVersion: snapshot.storage.k8s.io/v1"
echo "  kind: VolumeSnapshotClass"
echo "  metadata:"
echo "    name: longhorn-snapshot-class"
echo "    labels:"
echo "      kubeblocks.io/storage-snapshot-class: \"true\""
echo "  driver: driver.longhorn.io"
echo "  deletionPolicy: Delete"
echo "  parameters:"
echo "    type: snap"
echo "  EOF"
