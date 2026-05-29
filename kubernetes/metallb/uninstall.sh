#!/bin/bash
# 卸载 MetalLB.
#
# 顺序: 删 IPAddressPool/L2Advertisement → 删 native 清单 → namespace 自动消失.
# 注意: 现存的 LoadBalancer Service 在删 MetalLB 后会卡 EXTERNAL-IP <pending>,
#       不影响 ClusterIP / NodePort 流量, 但要换其他 LB 实现来接管.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="${VERSION:-v0.14.8}"
NS="metallb-system"

NATIVE_URL="https://raw.githubusercontent.com/metallb/metallb/${VERSION}/config/manifests/metallb-native.yaml"

echo "删除 pool.yaml (IPAddressPool / L2Advertisement) ..."
kubectl delete -f "${DIR}/pool.yaml" --ignore-not-found=true
echo ""

echo "删除 MetalLB 主体 ..."
kubectl delete -f "${NATIVE_URL}" --ignore-not-found=true
echo ""

echo "确认残留:"
kubectl get ns "${NS}" 2>/dev/null && echo "  ⚠ namespace 还在, 通常等几秒会自动清完"
kubectl get crd | grep metallb.io || echo "  ✓ 无 metallb CRD 残留"
