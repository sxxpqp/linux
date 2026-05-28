#!/bin/bash
set -e

NAMESPACE="observability"
PROM_NAMESPACE="monitoring"
# Prometheus CR 文件的位置（kube-prometheus 栈）
PROM_CR_FILE="$(cd "$(dirname "$0")/../prometheus/manifests" && pwd)/prometheus-prometheus.yaml"

echo "========================================="
echo " LGTM + Beyla 生产环境一键部署"
echo "========================================="
echo ""

# ---------- 前置检查 ----------
echo "[0/7] 前置检查..."

if ! command -v helm &>/dev/null; then
  echo "ERROR: helm 未安装"; exit 1
fi
if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl 未安装"; exit 1
fi

# 检查 kube-prometheus 已就位（必须先有 prometheus-operator + Prometheus CR）
if ! kubectl get prometheus k8s -n ${PROM_NAMESPACE} &>/dev/null; then
  echo "ERROR: 没找到 prometheus.${PROM_NAMESPACE}/k8s"
  echo "       请先部署 kube-prometheus 栈（见 kubernetes/prometheus/install-steps.md）"
  exit 1
fi

# eBPF 内核要求
KERNEL_VER=$(uname -r | cut -d. -f1,2)
echo "  内核版本: $KERNEL_VER (eBPF 需要 ≥ 5.14)"
echo "  前置检查通过"
echo ""

# ---------- Prometheus CR ----------
echo "[1/7] 配置 Prometheus (开 OTLP/Remote-Write Receiver + promote resource attrs)..."
if [ -f "$PROM_CR_FILE" ]; then
  kubectl apply -f "$PROM_CR_FILE"
  kubectl rollout status sts/prometheus-k8s -n ${PROM_NAMESPACE} --timeout=3m

  # 校验 reconcile 成功（避免静默冲突，详见会话经验：additionalArgs 与 operator-managed flag 冲突）
  RECONCILED=$(kubectl get prometheus k8s -n ${PROM_NAMESPACE} \
    -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}')
  if [ "$RECONCILED" != "True" ]; then
    echo "ERROR: Prometheus CR Reconciled=$RECONCILED"
    kubectl get prometheus k8s -n ${PROM_NAMESPACE} \
      -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].message}'; echo
    exit 1
  fi
  # 校验 OTLP + Remote-Write Receiver 已注入 pod 启动参数
  if ! kubectl exec -n ${PROM_NAMESPACE} prometheus-k8s-0 -c prometheus -- \
       cat /proc/1/cmdline | tr '\0' '\n' | grep -q "web.enable-remote-write-receiver"; then
    echo "WARN: prometheus-k8s-0 没启用 remote-write-receiver，服务图指标接收会失败"
  fi
  echo "  Prometheus 已就绪"
else
  echo "  WARN: 没找到 $PROM_CR_FILE，跳过（默认假设你已手动配好）"
fi
echo ""

# ---------- 创建命名空间 ----------
echo "[2/7] 创建命名空间 ${NAMESPACE}..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ---------- MinIO ----------
echo "[3/7] 部署 MinIO (S3 共享存储)..."
kubectl apply -f minio.yaml -n ${NAMESPACE}
kubectl wait --for=condition=ready pod -l app=minio -n ${NAMESPACE} --timeout=120s
echo "  MinIO 就绪"
echo ""

# ---------- Tempo ----------
echo "[4/7] 部署 Tempo (3副本 + S3 后端 + metrics-generator 双推 Prometheus)..."
helm repo add grafana https://nexus.ihome.sxxpqp.top:8443/repository/grafana/ --force-update 2>/dev/null || true
helm upgrade --install tempo grafana/tempo-distributed \
  -n ${NAMESPACE} -f tempo-values.yaml --timeout 10m
# 不加 --wait：ingester memberlist 慢启动 ~60s 容易触发超时；让 K8s 自己滚
kubectl rollout status sts/tempo-ingester -n ${NAMESPACE} --timeout=5m
kubectl rollout status deploy/tempo-distributor -n ${NAMESPACE} --timeout=3m
kubectl rollout status deploy/tempo-metrics-generator -n ${NAMESPACE} --timeout=3m
echo "  Tempo 就绪"
echo ""

# ---------- Alloy ----------
echo "[5/7] 部署 Alloy (ConfigMap + DaemonSet + Service，OTel 指标双推 Prometheus)..."
# 必须先创建 alloy-config ConfigMap（alloy.yaml 里只有 DaemonSet+Service，挂载它）
kubectl create configmap alloy-config -n ${NAMESPACE} \
  --from-file=config.alloy=alloy-config.alloy \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f alloy.yaml -n ${NAMESPACE}
# 如果 ConfigMap 后改、DaemonSet 不会自动重启，主动 restart 保证拿到新 config
kubectl rollout restart ds/alloy -n ${NAMESPACE}
kubectl rollout status ds/alloy -n ${NAMESPACE} --timeout=2m
echo "  Alloy 就绪"
echo ""

# ---------- Beyla ----------
echo "[6/7] 部署 Beyla (eBPF 自动埋点)..."
kubectl apply -f beyla.yaml -n ${NAMESPACE}
kubectl rollout status ds/beyla -n ${NAMESPACE} --timeout=2m
echo "  Beyla 就绪"
echo ""

# ---------- Grafana ----------
echo "[7/7] 部署 Grafana..."
helm upgrade --install grafana grafana/grafana \
  -n ${NAMESPACE} -f grafana-values.yaml --wait --timeout 3m
echo "  Grafana 就绪"
echo ""

# ---------- 验证 ----------
echo "========================================="
echo " 部署完成"
echo "========================================="
kubectl get pods -n ${NAMESPACE}
echo ""
echo "等待 60s 让数据回流后做链路验证..."
sleep 60
echo ""

echo "--- Prometheus 是否两个 pod 都收到 OTel 指标（HA 双推校验） ---"
for p in prometheus-k8s-0 prometheus-k8s-1; do
  CNT=$(kubectl exec -n ${PROM_NAMESPACE} $p -c prometheus -- \
    wget -qO- 'http://localhost:9090/api/v1/label/service_name/values?match[]=target_info' \
    2>/dev/null | grep -oE '"[a-z][^"]*"' | wc -l | tr -d ' ')
  echo "  $p: service_name 数量 = $CNT (期望 ≥ 3)"
done

echo ""
echo "--- 服务图指标（依赖 Tempo metrics-generator + Prometheus remote-write-receiver） ---"
RES=$(kubectl exec -n ${PROM_NAMESPACE} prometheus-k8s-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=count(traces_service_graph_request_total)' \
  2>/dev/null | grep -oE '"[0-9]+"' | head -1)
echo "  traces_service_graph_request_total series 数: ${RES:-0}"

echo ""
echo "========================================="
echo " 访问入口"
echo "========================================="
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[0].address}')
echo "Grafana:       http://${NODE_IP}:30300   (admin / admin123)"
echo "MinIO Console: kubectl port-forward svc/minio -n ${NAMESPACE} 9001:9001"
echo "               http://localhost:9001     (minioadmin / minioadmin)"
echo ""
echo "下一步："
echo "  kubectl apply -f test-apps.yaml          # 部署 Go/Java/Python 测试应用"
echo "  Grafana → Dashboards → 导入 ID 22784    # Lightweight APM for OpenTelemetry"
