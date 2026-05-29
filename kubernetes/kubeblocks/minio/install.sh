#!/bin/bash
# 部署 KubeBlocks MinIO Cluster (分布式 8 节点) + 稳定 ClusterIP + Console LoadBalancer.
#
# 前置:
#   - KubeBlocks operator 已装 (bash ../install.sh)
#   - minio addon 已 Enabled (kubectl get addon minio)
#   - 集群外要访问 Console UI → metallb 已就绪 (../metallb/install.sh)
#
# 用法:
#   bash install.sh                 # 默认 ns=test
#   bash install.sh --ns prod
#   bash install.sh --wait          # 等 Running + 写凭证到 ConfigMap (推荐)
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)   NS="$2"; shift 2 ;;
    --wait) WAIT=true; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 前置 ----------
if ! kubectl get crd clusters.apps.kubeblocks.io &>/dev/null; then
  echo "ERROR: KubeBlocks operator 未安装, 先跑 bash ../install.sh"; exit 1
fi
if ! kubectl get addon minio &>/dev/null; then
  echo "ERROR: minio addon 未注册. 启用方法:"
  echo "  kubectl patch addon minio --type=merge -p '{\"spec\":{\"install\":{\"enabled\":true}}}'"
  exit 1
fi

# ---------- 1. namespace ----------
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# ---------- 2. Cluster ----------
echo "部署 MinIO Cluster 到 namespace=${NS} (8 节点, 每节点 1Ti)..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/cluster.yaml" | kubectl apply -f -
echo ""

# ---------- 3. 稳定 Service ----------
echo "部署稳定 ClusterIP Service minio-cluster (集群内 S3 endpoint)..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/stable-service.yaml" | kubectl apply -f -

echo "部署 Console LoadBalancer Service (走 metallb)..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/console-service.yaml" | kubectl apply -f -
echo ""

# ---------- 4. 等就绪 ----------
if [ "$WAIT" = true ]; then
  echo "等 cluster.status.phase=Running (5-10 分钟, MinIO 8 节点 + PVC bind 比较慢)..."
  for i in $(seq 1 120); do
    STATUS=$(kubectl get cluster.apps.kubeblocks.io minio-cluster -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/120] phase=${STATUS:-<empty>}"
    [ "$STATUS" = "Running" ] && break
    [ "$STATUS" = "Failed" ] && { echo "  ✗ Failed"; break; }
    sleep 10
  done
  echo ""

  echo "等 Console LoadBalancer IP 分配..."
  for i in $(seq 1 30); do
    CONSOLE_LB=$(kubectl get svc -n "${NS}" minio-cluster-console \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    [ -n "$CONSOLE_LB" ] && break
    echo "  [$i/30] LB IP 还未分配..."
    sleep 5
  done
  echo ""
fi

# ---------- 5. 拉凭证 + 写 ConfigMap ----------
# KubeBlocks 给系统账号生成的 Secret 名一般是: minio-cluster-minio-account-root
SECRET_NAME=$(kubectl get secret -n "${NS}" -l app.kubernetes.io/instance=minio-cluster \
  -o name 2>/dev/null | grep -E 'account|conn-credential' | head -1 | sed 's|secret/||')

ROOT_USER=""
ROOT_PASS=""
if [ -n "$SECRET_NAME" ]; then
  ROOT_USER=$(kubectl get secret -n "${NS}" "${SECRET_NAME}" \
    -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null)
  ROOT_PASS=$(kubectl get secret -n "${NS}" "${SECRET_NAME}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null)
fi

CONSOLE_LB=$(kubectl get svc -n "${NS}" minio-cluster-console \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [ -n "$ROOT_USER" ] || [ -n "$CONSOLE_LB" ]; then
  echo "保存连接信息到 ConfigMap/minio-cluster-endpoints..."
  kubectl create configmap minio-cluster-endpoints -n "${NS}" \
    --from-literal=s3-internal="minio-cluster.${NS}.svc:9000" \
    --from-literal=console-external="${CONSOLE_LB:-<pending>}:9001" \
    --from-literal=root-user="${ROOT_USER}" \
    --from-literal=root-password="${ROOT_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo ""
fi

# ---------- 6. 连接信息 ----------
echo ""
echo "==============================================================="
echo " ✓ 连接信息"
echo "==============================================================="
echo ""

echo "------- 集群内 S3 API (业务代码用这个) -------"
echo ""
echo "  Endpoint:   http://minio-cluster.${NS}.svc:9000"
echo "  Region:     us-east-1 (MinIO 默认, 客户端 SDK 可任意填)"
[ -n "$ROOT_USER" ] && echo "  Access Key: ${ROOT_USER}"
[ -n "$ROOT_PASS" ] && echo "  Secret Key: ${ROOT_PASS}"
echo ""

echo "------- 集群外 Console UI (浏览器访问) -------"
echo ""
if [ -n "$CONSOLE_LB" ]; then
  echo "  URL:        http://${CONSOLE_LB}:9001"
else
  echo "  URL:        http://<LB-IP>:9001  (LB IP 还在分配, 看下面命令)"
  echo "  查 LB IP:   kubectl get svc -n ${NS} minio-cluster-console"
fi
[ -n "$ROOT_USER" ] && echo "  用户名:     ${ROOT_USER}"
[ -n "$ROOT_PASS" ] && echo "  密码:       ${ROOT_PASS}"
echo ""

if [ -z "$ROOT_USER" ]; then
  echo "------- ⚠ 没拿到凭证 -------"
  echo ""
  echo "  Secret 没找到, KubeBlocks addon 版本里凭证 Secret 名可能不一样, 手动查:"
  echo "    kubectl get secret -n ${NS} -l app.kubernetes.io/instance=minio-cluster"
  echo "    kubectl get secret -n ${NS} <secret-name> -o yaml"
  echo ""
fi

echo "------- 扩容说明 (重要) -------"
echo ""
echo "  ⚠ MinIO 不能改 replicas 扩容. 需要更多容量请:"
echo "    1. 不要改这个 Cluster 的 componentSpecs[0].replicas (会报错)"
echo "    2. 起一个新 Cluster (再加 4/8 节点), MinIO admin 加成一个新 Server Pool"
echo "    3. 或参考 KubeBlocks docs 的 server-pool 配置"
echo ""

echo "------- mc 客户端快速验证 -------"
echo ""
echo "  # 装 mc (本机)"
echo "  curl -O https://dl.min.io/client/mc/release/linux-amd64/mc && chmod +x mc"
echo ""
echo "  # 集群内验证 (从任一 pod 进去)"
echo "  kubectl exec -n ${NS} minio-cluster-minio-0 -- \\"
echo "    mc alias set local http://localhost:9000 \${ROOT_USER} \${ROOT_PASS}"
echo "  kubectl exec -n ${NS} minio-cluster-minio-0 -- mc admin info local"
echo ""

echo "------- Kubectl 快捷命令 -------"
echo ""
echo "  kubectl get pod,svc,pvc -n ${NS} -l app.kubernetes.io/instance=minio-cluster"
echo "  kubectl get cm minio-cluster-endpoints -n ${NS} -o yaml"
echo "  kubectl get cluster.apps.kubeblocks.io minio-cluster -n ${NS} -o wide"
