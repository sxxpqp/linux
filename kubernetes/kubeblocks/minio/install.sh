#!/bin/bash
# 部署 KubeBlocks MinIO Cluster (分布式 8 节点) + 稳定 ClusterIP + Console LoadBalancer.
#
# 前置:
#   - KubeBlocks operator 已装 (bash ../install.sh)
#   - minio addon 已 Enabled (脚本会自动检测 + 缺则 helm 装 + 启用)
#   - 集群外要访问 Console UI → metallb 已就绪 (../metallb/install.sh)
#
# 用法:
#   bash install.sh                       # 默认 ns=test
#   bash install.sh --ns prod
#   bash install.sh --wait                # 等 Running + 写凭证到 ConfigMap (推荐)
#   bash install.sh --addon-version 1.0.2 # 指定 minio addon chart 版本 (默认 1.0.2)
#   bash install.sh --addon-repo apecloud # helm 仓库 (默认 kubeblocks, 本地没就改 apecloud)
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false
ADDON_VERSION="1.0.2"
ADDON_REPO="kubeblocks"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)             NS="$2"; shift 2 ;;
    --wait)           WAIT=true; shift ;;
    --addon-version)  ADDON_VERSION="$2"; shift 2 ;;
    --addon-repo)     ADDON_REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 前置 ----------
if ! kubectl get crd clusters.apps.kubeblocks.io &>/dev/null; then
  echo "ERROR: KubeBlocks operator 未安装, 先跑 bash ../install.sh"; exit 1
fi

# ---------- 0. minio addon 检测 + 自动安装 + 启用 ----------
echo "[0/5] 检查 minio addon..."
ADDON_STATUS=$(kubectl get addon minio -o jsonpath='{.status.phase}' 2>/dev/null || true)

if [ -z "$ADDON_STATUS" ]; then
  # addon CR 不存在 → helm 装 chart 让 KB operator 自动注册
  echo "  minio addon 未注册, 用 helm 安装 chart..."
  command -v helm >/dev/null || { echo "  ERROR: helm 未安装, 装 helm 或手动 kubectl apply addon"; exit 1; }

  # 仓库可用性兜底: 没有就加 apecloud 公网
  if ! helm repo list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "${ADDON_REPO}"; then
    echo "  helm 仓库 '${ADDON_REPO}' 没加, 加 apecloud 公网..."
    helm repo add apecloud https://apecloud.github.io/helm-charts 2>/dev/null || true
    ADDON_REPO=apecloud
  fi
  helm repo update "${ADDON_REPO}" >/dev/null

  # --force-conflicts: KubeBlocks operator 接管了 ComponentDefinition 的 .spec.runtime.*,
  # helm 必须强制覆盖才能更新 image 等字段 (SSA 字段所有权冲突)
  helm upgrade --install kb-addon-minio "${ADDON_REPO}/minio" \
    -n kb-system --version "${ADDON_VERSION}" \
    --force-conflicts \
    || { echo "  ERROR: helm 装 minio chart 失败, 检查版本/仓库"; exit 1; }

  # 等 addon CR 注册进来 (KB operator 扫 helm release)
  echo "  等 KubeBlocks operator 注册 addon CR..."
  for i in $(seq 1 24); do
    ADDON_STATUS=$(kubectl get addon minio -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ -n "$ADDON_STATUS" ]; then
      echo "  ✓ addon 已注册, 当前 phase=${ADDON_STATUS}"
      break
    fi
    echo "  [$i/24] addon 还没出现, 5s 后重试 ..."
    sleep 5
  done

  if [ -z "$ADDON_STATUS" ]; then
    echo "  addon 仍未注册, 试重启 KubeBlocks operator..."
    kubectl -n kb-system rollout restart deploy kubeblocks >/dev/null
    kubectl -n kb-system rollout status deploy kubeblocks --timeout=2m || true
    for i in $(seq 1 12); do
      ADDON_STATUS=$(kubectl get addon minio -o jsonpath='{.status.phase}' 2>/dev/null || true)
      [ -n "$ADDON_STATUS" ] && break
      sleep 5
    done
  fi
fi

if [ -z "$ADDON_STATUS" ]; then
  echo "  ERROR: addon 装了 chart 但 CR 始终没注册, 手动看:"
  echo "    helm -n kb-system list | grep minio"
  echo "    kubectl -n kb-system logs deploy/kubeblocks | grep -i addon"
  exit 1
fi

# 还没 Enabled 就启用
if [ "$ADDON_STATUS" != "Enabled" ]; then
  echo "  addon phase=${ADDON_STATUS}, 启用中..."
  kubectl patch addon minio --type=merge \
    -p '{"spec":{"install":{"enabled":true}}}' >/dev/null

  for i in $(seq 1 24); do
    ADDON_STATUS=$(kubectl get addon minio -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$ADDON_STATUS" = "Enabled" ] && break
    echo "  [$i/24] phase=${ADDON_STATUS}, 5s 后重试 ..."
    sleep 5
  done

  [ "$ADDON_STATUS" = "Enabled" ] || { echo "  ERROR: addon 启用超时"; exit 1; }
fi
echo "  ✓ minio addon Enabled"

# 等 clusterdefinition 也注册进来 (cluster.yaml apply 需要)
echo "  等 clusterdefinition 'minio' 就绪..."
for i in $(seq 1 24); do
  if kubectl get clusterdefinition minio &>/dev/null; then
    echo "  ✓ clusterdefinition minio 已就绪"
    break
  fi
  echo "  [$i/24] 还没出现, 5s 后重试 ..."
  sleep 5
done
echo ""

# ---------- 1. namespace ----------
echo "[1/5] 创建 namespace ${NS} ..."
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ---------- 2. Cluster ----------
echo "[2/5] 部署 MinIO Cluster 到 namespace=${NS} (8 节点, 每节点 1Ti)..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/cluster.yaml" | kubectl apply -f -
echo ""

# ---------- 3. 稳定 Service ----------
echo "[3/5] 部署稳定 ClusterIP + Console LoadBalancer Service..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/stable-service.yaml" | kubectl apply -f -
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/console-service.yaml" | kubectl apply -f -
echo ""

# ---------- 4. 等就绪 ----------
if [ "$WAIT" = true ]; then
  echo "[4/5] 等 cluster.status.phase=Running (5-10 分钟, MinIO 8 节点 + PVC bind 比较慢)..."
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
else
  echo "[4/5] 跳过等待 (不带 --wait)"
  echo ""
fi

# ---------- 5. 拉凭证 + 写 ConfigMap ----------
echo "[5/5] 拉凭证 + 固化连接信息..."
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
