#!/bin/bash
# 安装 MetalLB (生产推荐的 Service LoadBalancer 实现).
#
# 默认 L2 (ARP) 模式. BGP 模式要交换机配合, 用 bgp.yaml 替代 pool.yaml 即可.
#
# 步骤:
#   1. 改 kube-proxy 为 strictARP=true (L2 模式必须, 否则 ARP 会乱回包)
#   2. apply upstream MetalLB native 清单 (controller + speaker + CRD)
#   3. 等 controller / speaker Ready
#   4. apply pool.yaml (IPAddressPool + L2Advertisement)
#
# 用法:
#   bash install.sh                     # 默认 v0.14.8 + native 清单
#   bash install.sh --version v0.14.5   # 指定版本
#   bash install.sh --skip-strict-arp   # 自己已经改过 kube-proxy 就加这个
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="v0.14.8"
NS="metallb-system"
SKIP_STRICT_ARP=false

while [ $# -gt 0 ]; do
  case "$1" in
    --version)         VERSION="$2"; shift 2 ;;
    --skip-strict-arp) SKIP_STRICT_ARP=true; shift ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

# 上游清单 (官方 release 直发的 single-file 清单)
NATIVE_URL="https://raw.githubusercontent.com/metallb/metallb/${VERSION}/config/manifests/metallb-native.yaml"

echo "========================================="
echo " MetalLB 安装"
echo "  version:    ${VERSION}"
echo "  namespace:  ${NS}"
echo "  manifest:   ${NATIVE_URL}"
echo "========================================="
echo ""

# ---------- 前置 ----------
command -v kubectl >/dev/null || { echo "ERROR: kubectl 未安装"; exit 1; }

# ---------- 1. kube-proxy strictARP ----------
# L2 模式: speaker 在 leader 节点回 ARP. kube-proxy IPVS 默认会代答, 会抢答导致 VIP 抖动.
# 改 strictARP=true 让 kube-proxy 闭嘴, MetalLB speaker 独占 ARP.
# iptables 模式不受影响, 但改了也没副作用, 统一改更稳.
if [ "$SKIP_STRICT_ARP" = false ]; then
  echo "[1/3] 改 kube-proxy strictARP=true ..."
  CURRENT=$(kubectl get configmap -n kube-system kube-proxy \
    -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -E '^\s*strictARP:' | awk '{print $2}')
  if [ "$CURRENT" = "true" ]; then
    echo "  ✓ 已经是 true, 跳过"
  else
    kubectl get configmap -n kube-system kube-proxy -o yaml \
      | sed 's/strictARP: false/strictARP: true/' \
      | kubectl apply -f - >/dev/null
    echo "  ✓ ConfigMap 已 patch, rollout 重启 kube-proxy ..."
    kubectl -n kube-system rollout restart daemonset kube-proxy
    kubectl -n kube-system rollout status daemonset kube-proxy --timeout=2m || true
  fi
  echo ""
else
  echo "[1/3] 跳过 strictARP 修改 (--skip-strict-arp)"
  echo ""
fi

# ---------- 2. apply native 清单 ----------
echo "[2/3] 安装 MetalLB 主体 (controller + speaker + CRD) ..."
if ! kubectl apply -f "${NATIVE_URL}"; then
  echo ""
  echo "  ERROR: 从 GitHub 拉清单失败. 离线 / 国内拉不到可以:"
  echo "    1. 本机 curl -kLo metallb-native.yaml ${NATIVE_URL}"
  echo "    2. (可选) 把 image 改成内网镜像源 (quay.io/metallb → 你的 mirror)"
  echo "    3. kubectl apply -f metallb-native.yaml"
  exit 1
fi
echo ""

# ---------- 3. 等 ready ----------
echo "[3/3] 等 controller / speaker Ready ..."
kubectl -n "${NS}" rollout status deploy/controller --timeout=3m || true
kubectl -n "${NS}" rollout status ds/speaker --timeout=3m || true
echo ""

# ---------- 4. 配置池子 ----------
echo "应用 IP 池配置 (pool.yaml) ..."
# CRD 刚 apply, webhook 可能要几秒才就绪, 失败重试几次
for i in $(seq 1 12); do
  if kubectl apply -f "${DIR}/pool.yaml" 2>/dev/null; then
    echo "  ✓ pool.yaml 已应用"
    break
  fi
  echo "  [$i/12] webhook 还没就绪, 5s 后重试 ..."
  sleep 5
done
echo ""

echo "==============================================================="
echo " ✓ MetalLB 装完"
echo "==============================================================="
echo ""
echo "组件状态:"
kubectl -n "${NS}" get pod
echo ""
echo "IP 池:"
kubectl -n "${NS}" get ipaddresspool
echo ""
echo "通告:"
kubectl -n "${NS}" get l2advertisement
echo ""
echo "测试 (建一个 LB Service 看 EXTERNAL-IP):"
echo "  kubectl create deploy nginx --image=nginx"
echo "  kubectl expose deploy nginx --port=80 --type=LoadBalancer"
echo "  kubectl get svc nginx -w"
echo ""
echo "改 IP 池: 编辑 pool.yaml 再 kubectl apply -f pool.yaml"
