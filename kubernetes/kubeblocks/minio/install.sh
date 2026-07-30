#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/minio/install.sh
# 部署 KubeBlocks MinIO 分布式集群 (官方 addon, 替代 Bitnami Helm 版).
#
# 与 ../minio-bitnami/ 的区别:
#   - 统一用 KubeBlocks Cluster CR + OpsRequest 管理
#   - 支持水平扩缩容 / 重启 / 备份 (跟 Redis/MySQL/Kafka 同一套 API)
#   - 自带 Grafana dashboard + exporter
#
# 用法:
#   bash install.sh                          # 默认 ns=test, 4 副本
#   bash install.sh --ns prod --replicas 8
#   bash install.sh --wait                   # 等 Running + 拉凭证
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false
REPLICAS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)       NS="$2"; shift 2 ;;
    --replicas) REPLICAS="$2"; shift 2 ;;
    --wait)     WAIT=true; shift ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 前置 ----------
if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl 未安装"; exit 1
fi
if ! kubectl get crd clusters.apps.kubeblocks.io &>/dev/null; then
  echo "ERROR: KubeBlocks operator 未安装, 先跑 bash ../install.sh"
  exit 1
fi

# ---------- 0. 检查 minio addon ----------
echo "检查 minio addon..."
ADDON_PHASE=$(kubectl get addons.extensions.kubeblocks.io minio \
  -o jsonpath='{.status.phase}' 2>/dev/null || true)

if [ -z "$ADDON_PHASE" ]; then
  echo "  ✗ minio addon 未找到, 请确认 KubeBlocks 版本包含 minio addon"
  echo "    kubectl get addon | grep minio"
  exit 1
fi

if [ "$ADDON_PHASE" != "Enabled" ]; then
  echo "  当前 phase=${ADDON_PHASE}, 启用中..."
  kubectl patch addons.extensions.kubeblocks.io minio \
    --type=merge -p '{"spec":{"install":{"enabled":true}}}' || {
    echo "  ✗ patch addon 失败"
    exit 1
  }
  for i in $(seq 1 30); do
    P=$(kubectl get addons.extensions.kubeblocks.io minio \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/30] addon phase=${P}"
    [ "$P" = "Enabled" ] && break
    sleep 5
  done
  if [ "$P" != "Enabled" ]; then
    echo "  ✗ addon 启用超时"
    exit 1
  fi
fi
echo "  ✓ minio addon 已启用"
echo ""

# ---------- 1. namespace ----------
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# ---------- 2. 部署 Cluster ----------
echo "部署 MinIO Cluster 到 namespace=${NS}..."
if [ -n "$REPLICAS" ]; then
  sed -e "s|namespace: test|namespace: ${NS}|g" \
      -e "s|replicas: 4|replicas: ${REPLICAS}|" \
      "${DIR}/cluster.yaml" | kubectl apply -f -
else
  sed "s|namespace: test|namespace: ${NS}|g" "${DIR}/cluster.yaml" | kubectl apply -f -
fi
echo ""

# ---------- 3. 等就绪 ----------
if [ "$WAIT" = true ]; then
  echo "等 cluster.status.phase=Running (3-8 分钟, MinIO 纠删码初始化较慢)..."
  for i in $(seq 1 90); do
    STATUS=$(kubectl get cluster.apps.kubeblocks.io minio-cluster -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/90] phase=${STATUS:-<empty>}"
    [ "$STATUS" = "Running" ] && break
    [ "$STATUS" = "Failed" ] && { echo "  ✗ Failed"; break; }
    sleep 10
  done
  echo ""
fi

# ---------- 4. 拉凭证 ----------
echo "拉取 root 凭证..."
ROOT_USER=$(kubectl get secret -n "${NS}" minio-cluster-minio-account-root \
  -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
ROOT_PASS=$(kubectl get secret -n "${NS}" minio-cluster-minio-account-root \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

# ---------- 5. 连接信息 ----------
echo ""
echo "==============================================================="
echo " ✓ MinIO 连接信息 (KubeBlocks 管理)"
echo "==============================================================="
echo ""
echo "------- 集群内 S3 API (业务代码用这个) -------"
echo ""
echo "  Endpoint:   http://minio-cluster-minio.${NS}.svc:9000"
echo "  Region:     us-east-1"
[ -n "$ROOT_USER" ] && echo "  Access Key: ${ROOT_USER}"
[ -n "$ROOT_PASS" ] && echo "  Secret Key: ${ROOT_PASS}"
echo ""

echo "------- Console UI -------"
echo ""
echo "  port-forward (推荐):"
echo "    kubectl port-forward -n ${NS} svc/minio-cluster-frontend 9001:9001"
echo "    浏览器打开 http://localhost:9001"
echo ""
echo "  或 NodePort (需自行 expose):"
echo "    kubectl expose svc minio-cluster-frontend -n ${NS} --type=NodePort --name=minio-console-np"
echo ""
[ -n "$ROOT_USER" ] && echo "  用户名: ${ROOT_USER}"
[ -n "$ROOT_PASS" ] && echo "  密码:   ${ROOT_PASS}"
echo ""

if [ -z "$ROOT_USER" ]; then
  echo "------- ⚠ 凭证还没就绪 -------"
  echo "  等 pod Running 后再查:"
  echo "    kubectl get secret -n ${NS} minio-cluster-minio-account-root -o jsonpath='{.data.password}' | base64 -d; echo"
  echo ""
fi

echo "------- 运维命令 -------"
echo ""
echo "  查看集群:   kubectl get cluster minio-cluster -n ${NS}"
echo "  查看 pod:   kubectl get pod -n ${NS} -l app.kubernetes.io/instance=minio-cluster"
echo "  查看 svc:   kubectl get svc -n ${NS} -l app.kubernetes.io/instance=minio-cluster"
echo "  扩缩容:     bash scale.sh 6 --ns ${NS}"
echo "  重启:       bash restart.sh --ns ${NS}"
echo "  卸载:       bash uninstall.sh --ns ${NS}"
echo ""
echo "------- mc 客户端验证 -------"
echo ""
echo "  mc alias set local http://minio-cluster-minio.${NS}.svc:9000 '${ROOT_USER}' '${ROOT_PASS}'"
echo "  mc admin info local"
echo ""
