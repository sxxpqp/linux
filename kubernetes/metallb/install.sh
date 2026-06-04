#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/metallb/install.sh
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

# native 清单优先级:
#   1. 同目录下的 metallb-native.yaml (离线 / Nexus 不通时用)
#   2. --manifest <path|url> 显式指定
#   3. Nexus raw 代理 (在线兜底)
NATIVE_LOCAL="${DIR}/metallb-native.yaml"
NATIVE_URL="https://nexus.ihome.sxxpqp.top:8443/metallb/metallb/${VERSION}/config/manifests/metallb-native.yaml"

if [ -f "${NATIVE_LOCAL}" ]; then
  NATIVE_SRC="${NATIVE_LOCAL}"
  NATIVE_DESC="local (${NATIVE_LOCAL})"
else
  NATIVE_SRC="${NATIVE_URL}"
  NATIVE_DESC="upstream (${NATIVE_URL})"
fi

echo "========================================="
echo " MetalLB 安装"
echo "  version:    ${VERSION}"
echo "  namespace:  ${NS}"
echo "  manifest:   ${NATIVE_DESC}"
echo "========================================="
echo ""

# ---------- 前置 ----------
command -v kubectl >/dev/null || { echo "ERROR: kubectl 未安装"; exit 1; }

# ---------- 1. kube-proxy strictARP ----------
# L2 模式: speaker 在 leader 节点回 ARP. kube-proxy IPVS 默认会代答, 会抢答导致 VIP 抖动.
# 改 strictARP=true 让 kube-proxy 闭嘴, MetalLB speaker 独占 ARP.
# iptables 模式不受影响, 但改了也没副作用, 统一改更稳.
# 步骤顺序: 实际可能是 4 步(有 kube-proxy) 或 3 步(无 kube-proxy)
STEP=1; TOTAL=4
if ! kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
  TOTAL=3
fi

if [ "$SKIP_STRICT_ARP" = false ]; then
  echo "[${STEP}/${TOTAL}] 改 kube-proxy strictARP=true ..."
  if ! kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
    echo "  kube-proxy DaemonSet 不存在(已用 Calico BPF 替换), 跳过 strictARP"
  else
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
  fi
  echo ""
else
  echo "[${STEP}/${TOTAL}] 跳过 strictARP 修改 (--skip-strict-arp)"
  echo ""
fi
STEP=$((STEP+1))

# ---------- 2. apply native 清单 ----------
echo "[${STEP}/${TOTAL}] 安装 MetalLB 主体 (controller + speaker + CRD) ..."
STEP=$((STEP+1))
if ! kubectl apply -f "${NATIVE_SRC}"; then
  echo ""
  if [ "${NATIVE_SRC}" = "${NATIVE_URL}" ]; then
    echo "  ERROR: 从 Nexus 拉清单失败. 离线 / Nexus 不通时可以:"
    echo "    1. 本机下载: curl -kLo ${NATIVE_LOCAL} ${NATIVE_URL}"
    echo "    2. (可选) 改 image 为内网 mirror (quay.io/metallb → 你的源)"
    echo "    3. 重跑 bash install.sh (会自动用本地 metallb-native.yaml)"
  else
    echo "  ERROR: 本地清单 apply 失败, 检查:"
    echo "    1. ${NATIVE_LOCAL} 是否完整"
    echo "    2. kubectl 是否能连到 apiserver"
  fi
  exit 1
fi
echo ""

# ---------- 3. 等 ready ----------
echo "[${STEP}/${TOTAL}] 等 controller / speaker Ready ..."
STEP=$((STEP+1))
kubectl -n "${NS}" rollout status deploy/controller --timeout=3m || true
kubectl -n "${NS}" rollout status ds/speaker --timeout=3m || true

# 额外等 webhook 真正就绪 (rollout status 返回早, webhook 后注册).
# 标志: webhook-service 的 Endpoints 有 IP 了, 才算 apply CR 不会被打回.
echo "  等 webhook 注册 endpoint ..."
for i in $(seq 1 24); do
  EP=$(kubectl -n "${NS}" get endpoints webhook-service -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
  if [ -n "$EP" ]; then
    echo "  ✓ webhook endpoint 就绪: ${EP}"
    break
  fi
  echo "  [$i/24] webhook 还未注册, 5s 后重试 ..."
  sleep 5
done
echo ""

# ---------- 4. 配置池子 ----------
echo "[${STEP}/${TOTAL}] 应用 IP 池配置 (pool.yaml) ..."
# CRD 刚 apply, webhook 可能要几秒才就绪, 失败重试几次.
# 前 N-1 次失败吞错误避免刷屏, 最后一次把 stderr 暴露出来 (避免静默失败)
POOL_APPLIED=false
for i in $(seq 1 12); do
  if [ "$i" -lt 12 ]; then
    if kubectl apply -f "${DIR}/pool.yaml" 2>/dev/null; then
      POOL_APPLIED=true; break
    fi
    echo "  [$i/12] webhook 还没就绪, 5s 后重试 ..."
    sleep 5
  else
    # 最后一次: 让 kubectl 把真实错误打出来, 不再吞
    echo "  [$i/12] 最后一次尝试 (显示真实错误):"
    if kubectl apply -f "${DIR}/pool.yaml"; then
      POOL_APPLIED=true
    fi
  fi
done

if [ "$POOL_APPLIED" = true ]; then
  echo "  ✓ pool.yaml 已应用"
else
  echo ""
  echo "  ⚠ pool.yaml 始终没应用上. 集群里没有 IPAddressPool, LB Service 会一直 <pending>."
  echo "    手动补:  kubectl apply -f ${DIR}/pool.yaml"
  echo "    排查:    kubectl -n ${NS} get pod; kubectl -n ${NS} logs deploy/controller"
fi
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
