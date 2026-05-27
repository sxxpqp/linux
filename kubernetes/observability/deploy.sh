#!/bin/bash
set -e

NAMESPACE="observability"

echo "========================================="
echo " LGTM + Beyla 生产环境一键部署"
echo "========================================="
echo ""

# ---------- 前置检查 ----------
echo "[0/6] 前置检查..."

if ! command -v helm &>/dev/null; then
  echo "ERROR: helm 未安装"
  exit 1
fi

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl 未安装"
  exit 1
fi

# 检查内核版本（eBPF 需要 ≥ 5.14）
KERNEL_VER=$(uname -r | cut -d. -f1,2)
echo "  内核版本: $KERNEL_VER (eBPF 需要 ≥ 5.14)"

echo "  前置检查通过"
echo ""

# ---------- 创建命名空间 ----------
echo "[1/6] 创建命名空间..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ---------- MinIO ----------
echo "[2/6] 部署 MinIO (S3 共享存储)..."
kubectl apply -f minio.yaml -n ${NAMESPACE}
kubectl wait --for=condition=ready pod -l app=minio -n ${NAMESPACE} --timeout=120s
echo "  MinIO 就绪"
echo ""

# ---------- Tempo ----------
echo "[3/6] 部署 Tempo (3副本 + S3后端)..."
helm repo add grafana https://nexus.ihome.sxxpqp.top:8443/repository/grafana --force-update 2>/dev/null
helm upgrade --install tempo grafana/tempo-distributed \
  -n ${NAMESPACE} \
  -f tempo-values.yaml \
  --wait --timeout 5m
echo "  Tempo 就绪"
echo ""

# ---------- Alloy ----------
echo "[4/6] 部署 Alloy (ConfigMap + DaemonSet + Service)..."
# 必须先创建 alloy-config ConfigMap（alloy.yaml 里只有 DaemonSet+Service，挂载它）
kubectl create configmap alloy-config -n ${NAMESPACE} \
  --from-file=config.alloy=alloy-config.alloy \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f alloy.yaml -n ${NAMESPACE}
kubectl wait --for=condition=ready pod -l app=alloy -n ${NAMESPACE} --timeout=120s
echo "  Alloy 就绪"
echo ""

# ---------- Beyla ----------
echo "[5/6] 部署 Beyla (eBPF 自动埋点)..."
kubectl apply -f beyla.yaml -n ${NAMESPACE}
# DaemonSet 没有 condition=ready，用 rollout status
kubectl rollout status daemonset/beyla -n ${NAMESPACE} --timeout=120s
echo "  Beyla 就绪"
echo ""

# ---------- Grafana ----------
echo "[6/6] 部署 Grafana..."
helm upgrade --install grafana grafana/grafana \
  -n ${NAMESPACE} \
  -f grafana-values.yaml \
  --wait --timeout 3m
echo "  Grafana 就绪"
echo ""

# ---------- 验证 ----------
echo "========================================="
echo " 部署完成，验证状态："
echo "========================================="
kubectl get pods -n ${NAMESPACE}
echo ""
echo "Grafana: http://$(kubectl get node -o jsonpath='{.items[0].status.addresses[0].address}'):30300"
echo "用户名: admin"
echo "密码: admin123"
echo ""
echo "MinIO Console:"
echo "  kubectl port-forward svc/minio -n ${NAMESPACE} 9001:9001"
echo "  http://localhost:9001 (minioadmin / minioadmin)"
