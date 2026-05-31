#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/prometheus/install.sh
# 安装 kube-prometheus 监控栈 (原始 manifests 方式, 非 helm chart)。
# 包含: prometheus-operator + prometheus + alertmanager + node-exporter
#       + kube-state-metrics + grafana + blackbox-exporter + prometheus-adapter
# 用法:
#   bash install.sh                  # 完整安装
#   bash install.sh --skip-crd       # 跳过 CRD 安装（CRD 已存在时复跑）
#   bash install.sh --dry-run        # 预演
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="${DIR}/manifests"
SETUP="${MANIFESTS}/setup"
SKIP_CRD=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --skip-crd) SKIP_CRD=true ;;
    --dry-run)  DRY_RUN=true ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $arg (使用 --help 查看用法)"; exit 1 ;;
  esac
done

run() {
  echo "  \$ $*"
  [ "$DRY_RUN" = false ] && { "$@" || echo "  (失败，继续)"; }
}

echo "========================================="
echo " kube-prometheus 监控栈安装"
echo "  manifests:  ${MANIFESTS}"
echo "  skip-crd:   ${SKIP_CRD}"
echo "  dry-run:    ${DRY_RUN}"
echo "========================================="
echo ""

# 前置检查
if [ ! -d "${MANIFESTS}" ]; then
  echo "ERROR: manifests 目录不存在: ${MANIFESTS}"
  exit 1
fi
if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl 未安装"
  exit 1
fi

# ---------- 1. CRD + Namespace（必须先于其他资源） ----------
if [ "$SKIP_CRD" = false ]; then
  echo "[1/3] 安装 CRD 和 namespace (setup/)..."
  # --server-side 避免 last-applied annotation 太大报错（CRD 文件常常超过 256KB 上限）
  run kubectl apply --server-side -f "${SETUP}/"

  echo ""
  echo "  等待 CRD 注册..."
  run kubectl wait --for=condition=Established crd/prometheuses.monitoring.coreos.com --timeout=60s
  run kubectl wait --for=condition=Established crd/servicemonitors.monitoring.coreos.com --timeout=60s
else
  echo "[1/3] 跳过 CRD 安装 (--skip-crd)"
fi
echo ""

# ---------- 2. 主体组件 ----------
echo "[2/3] 安装 prometheus-operator 和所有组件..."
# 重要：在第一次启动 operator 之前不要 apply Prometheus/Alertmanager CR
# 但实际整个目录一起 apply 也没问题，operator pod 起来后会自己 reconcile
run kubectl apply -f "${MANIFESTS}/"
echo ""

# ---------- 3. 等待就绪 ----------
echo "[3/3] 等待主要组件就绪..."
run kubectl rollout status deploy/prometheus-operator -n monitoring --timeout=3m
run kubectl rollout status statefulset/prometheus-k8s -n monitoring --timeout=5m
run kubectl rollout status statefulset/alertmanager-main -n monitoring --timeout=3m
run kubectl rollout status deploy/grafana -n monitoring --timeout=2m
run kubectl rollout status deploy/kube-state-metrics -n monitoring --timeout=2m
run kubectl rollout status daemonset/node-exporter -n monitoring --timeout=2m
echo ""

# ---------- 验证 ----------
echo "========================================="
echo " 安装完成"
echo "========================================="
kubectl get pods -n monitoring
echo ""

# 检查 Reconciled 状态（CR 的 spec 错了 operator 会卡住）
RECONCILED=$(kubectl get prometheus k8s -n monitoring \
  -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null)
if [ "$RECONCILED" != "True" ]; then
  echo "⚠️  Prometheus CR Reconciled = ${RECONCILED:-未知}"
  kubectl get prometheus k8s -n monitoring \
    -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].message}' 2>/dev/null; echo
else
  echo "✅ Prometheus CR Reconciled = True"
fi
echo ""

echo "访问入口（默认 ClusterIP，需要 port-forward 或加 NodePort/Ingress）："
echo "  Prometheus:    kubectl -n monitoring port-forward svc/prometheus-k8s 9090"
echo "  Alertmanager:  kubectl -n monitoring port-forward svc/alertmanager-main 9093"
echo "  Grafana:       kubectl -n monitoring port-forward svc/grafana 3000   (admin/admin)"
