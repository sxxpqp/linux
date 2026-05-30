#!/bin/bash
# 部署 MinIO 分布式集群 (8 节点) - 用 Bitnami helm chart
#
# 跟 KubeBlocks 官方推荐一致 (https://kubeblocks.io/docs/preview/user_docs/references/install-minio),
# 但官方默认 standalone,这里改成 distributed 8 节点用作业务对象存储集群.
#
# 用法:
#   bash install.sh                       # 默认 ns=test, 8 节点, 每节点 1Ti
#   bash install.sh --ns prod
#   bash install.sh --replicas 4          # 改节点数 (≥4 且 4 的倍数,推荐 4/8/16)
#   bash install.sh --storage 100Gi       # 每节点存储大小
#   bash install.sh --version 14.10.5     # chart 版本 (官方文档当前推荐版本)
#   bash install.sh --wait                # 等 ready + 拉凭证 + 配 LB
#
# 前置:
#   - helm 已装
#   - 集群外要访问 Console UI → metallb 已就绪 (../metallb/install.sh)
#   - containerd 配了 docker.io mirror 到 Harbor (../containerd-registry-mirror.sh)
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
REPLICAS=8
STORAGE="1Ti"
CHART_VERSION="14.10.5"
# Bitnami chart 走 Harbor 代理(docker.io 直连国内超时).
# Harbor 前端 nginx 自动 rewrite /v2/* → /v2/dockerhub/*,所以路径不带 /dockerhub.
# 如果 Harbor 拿不到,可临时改回 oci://registry-1.docker.io/bitnamicharts/minio
CHART_OCI="oci://huball.ihome.sxxpqp.top:8443/bitnamicharts/minio"
RELEASE_NAME="minio-cluster"
WAIT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)        NS="$2"; shift 2 ;;
    --replicas)  REPLICAS="$2"; shift 2 ;;
    --storage)   STORAGE="$2"; shift 2 ;;
    --version)   CHART_VERSION="$2"; shift 2 ;;
    --wait)      WAIT=true; shift ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 前置检查 ----------
command -v helm >/dev/null    || { echo "ERROR: helm 未安装"; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl 未安装"; exit 1; }

# 校验 replicas (Bitnami chart distributed 要求 ≥4 且为偶数)
if [ "$REPLICAS" -lt 4 ] || [ $((REPLICAS % 2)) -ne 0 ]; then
  echo "ERROR: --replicas 必须 ≥4 且为偶数 (推荐 4/6/8/16), 当前: ${REPLICAS}"
  exit 1
fi

echo "==============================================================="
echo " MinIO 分布式集群部署"
echo "==============================================================="
echo "  release:      ${RELEASE_NAME}"
echo "  namespace:    ${NS}"
echo "  replicas:     ${REPLICAS}"
echo "  storage:      ${STORAGE} / 节点"
echo "  chart:        bitnami/minio ${CHART_VERSION}"
echo "==============================================================="
echo ""

# ---------- 1. namespace ----------
echo "[1/4] 创建 namespace ${NS} ..."
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ---------- 2. helm install ----------
# OCI chart 从 Harbor (代理 docker.io) 拉,helm 4.1+ 原生支持 OCI.
# 镜像层走 containerd 的 hosts.toml 透明 mirror 到 Harbor.
#
# image.repository 系列改成 bitnamilegacy/*:
#   Bitnami 2025-08 把免费 image 归档到 bitnamilegacy namespace,原 bitnami/<x>
#   tag 仍在 chart 默认值里但 docker hub 已删除. 必须重定向到 legacy 才能拉.
echo "[2/4] helm install Bitnami MinIO chart..."
helm upgrade --install "${RELEASE_NAME}" \
  "${CHART_OCI}" \
  --namespace "${NS}" \
  --version "${CHART_VERSION}" \
  --insecure-skip-tls-verify \
  --set mode=distributed \
  --set statefulset.replicaCount="${REPLICAS}" \
  --set persistence.size="${STORAGE}" \
  --set image.repository=bitnamilegacy/minio \
  --set clientImage.repository=bitnamilegacy/minio-client \
  --set volumePermissions.image.repository=bitnamilegacy/os-shell \
  --set global.security.allowInsecureImages=true \
  --set resources.limits.cpu=4 \
  --set resources.limits.memory=8Gi \
  --set resources.requests.cpu=500m \
  --set resources.requests.memory=2Gi \
  --set "extraEnvVars[0].name=MINIO_BROWSER_LOGIN_ANIMATION" \
  --set "extraEnvVars[0].value=off" \
  || { echo "ERROR: helm install 失败"; exit 1; }
echo ""

# ---------- 3. Console LoadBalancer Service (单独暴露 9001,API 9000 留内网) ----------
echo "[3/4] 部署 Console LoadBalancer Service (port 9001)..."
sed -e "s|namespace: test|namespace: ${NS}|" \
    -e "s|__RELEASE_NAME__|${RELEASE_NAME}|g" \
    "${DIR}/console-service.yaml" | kubectl apply -f -
echo ""

# ---------- 4. 等就绪 ----------
if [ "$WAIT" = true ]; then
  echo "[4/4] 等 StatefulSet ready (5-10 分钟, MinIO 8 节点 + PVC bind 比较慢)..."
  kubectl -n "${NS}" rollout status statefulset/"${RELEASE_NAME}" --timeout=10m || true
  echo ""

  echo "等 Console LoadBalancer IP 分配..."
  for i in $(seq 1 30); do
    CONSOLE_LB=$(kubectl get svc -n "${NS}" "${RELEASE_NAME}-console" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    [ -n "$CONSOLE_LB" ] && break
    echo "  [$i/30] LB IP 还未分配..."
    sleep 5
  done
  echo ""
else
  echo "[4/4] 跳过等待 (不带 --wait)"
  echo ""
fi

# ---------- 5. 拉凭证 + 写 ConfigMap ----------
echo "拉凭证 + 固化连接信息..."
ROOT_USER=$(kubectl get secret -n "${NS}" "${RELEASE_NAME}" \
  -o jsonpath="{.data.root-user}" 2>/dev/null | base64 -d 2>/dev/null)
ROOT_PASS=$(kubectl get secret -n "${NS}" "${RELEASE_NAME}" \
  -o jsonpath="{.data.root-password}" 2>/dev/null | base64 -d 2>/dev/null)
CONSOLE_LB=$(kubectl get svc -n "${NS}" "${RELEASE_NAME}-console" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [ -n "$ROOT_USER" ] || [ -n "$CONSOLE_LB" ]; then
  kubectl create configmap "${RELEASE_NAME}-endpoints" -n "${NS}" \
    --from-literal=s3-internal="${RELEASE_NAME}.${NS}.svc.cluster.local:9000" \
    --from-literal=console-external="${CONSOLE_LB:-<pending>}:9001" \
    --from-literal=root-user="${ROOT_USER}" \
    --from-literal=root-password="${ROOT_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ---------- 6. 输出 ----------
echo ""
echo "==============================================================="
echo " ✓ 连接信息"
echo "==============================================================="
echo ""

echo "------- 集群内 S3 API (业务代码用这个) -------"
echo ""
echo "  Endpoint:   http://${RELEASE_NAME}.${NS}.svc.cluster.local:9000"
echo "  Region:     us-east-1 (MinIO 默认, 客户端 SDK 可任意填)"
[ -n "$ROOT_USER" ] && echo "  Access Key: ${ROOT_USER}"
[ -n "$ROOT_PASS" ] && echo "  Secret Key: ${ROOT_PASS}"
echo ""

echo "------- 集群外 Console UI (浏览器访问) -------"
echo ""
if [ -n "$CONSOLE_LB" ]; then
  echo "  URL:        http://${CONSOLE_LB}:9001"
else
  echo "  URL:        http://<LB-IP>:9001  (LB IP 还在分配,看下面命令)"
  echo "  查 LB IP:   kubectl get svc -n ${NS} ${RELEASE_NAME}-console"
  echo "  临时用 port-forward (不依赖 LB):"
  echo "    kubectl -n ${NS} port-forward svc/${RELEASE_NAME} 9001:9001"
fi
[ -n "$ROOT_USER" ] && echo "  用户名:     ${ROOT_USER}"
[ -n "$ROOT_PASS" ] && echo "  密码:       ${ROOT_PASS}"
echo ""

if [ -z "$ROOT_USER" ]; then
  echo "------- ⚠ 没拿到凭证 -------"
  echo "  Secret 还没就绪,稍等再查:"
  echo "    kubectl get secret -n ${NS} ${RELEASE_NAME} -o yaml"
  echo ""
fi

echo "------- 扩容说明 (重要) -------"
echo ""
echo "  ⚠ MinIO distributed 不能直接改 replicas. 需要更多容量请:"
echo "    1. 不要 helm upgrade 改 statefulset.replicaCount (会数据不一致)"
echo "    2. 起新的 MinIO 集群 (独立 release), 用 admin 命令做 server-pool 联邦"
echo "    3. 或者 PVC 单独扩容: kubectl edit pvc -n ${NS} data-${RELEASE_NAME}-0 ..."
echo ""

echo "------- mc 客户端快速验证 -------"
echo ""
echo "  # 装 mc (本机)"
echo "  curl -O https://dl.min.io/client/mc/release/linux-amd64/mc && chmod +x mc"
echo ""
echo "  # 配 alias 后测试"
echo "  ./mc alias set local http://${RELEASE_NAME}.${NS}.svc.cluster.local:9000 \\"
echo "    '${ROOT_USER}' '${ROOT_PASS}'"
echo "  ./mc admin info local"
echo "  ./mc mb local/test-bucket"
echo ""

echo "------- Kubectl 快捷命令 -------"
echo ""
echo "  kubectl -n ${NS} get pod,svc,pvc -l app.kubernetes.io/instance=${RELEASE_NAME}"
echo "  kubectl -n ${NS} get cm ${RELEASE_NAME}-endpoints -o yaml"
echo "  kubectl -n ${NS} logs -l app.kubernetes.io/instance=${RELEASE_NAME} -c minio --tail=50"
