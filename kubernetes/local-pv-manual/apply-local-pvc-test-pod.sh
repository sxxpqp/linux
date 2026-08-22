#!/usr/bin/env bash
# 系统: 管理机渲染并 apply manual local PV 测试 Pod 模板
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/local-pv-manual/apply-local-pvc-test-pod.sh
# 用法: curl -sL <URL> -o apply-local-pvc-test-pod.sh && bash apply-local-pvc-test-pod.sh [变量覆盖]
#
# 默认值说明:
#   - 不传环境变量时,使用下面的默认值
#   - 需要测别的 PVC/命名空间时,直接 export 覆盖后再执行即可
#
# 示例:
#   bash apply-local-pvc-test-pod.sh
#   TEST_POD_NAME=local-ssd-test-pod PVC_NAME=ssd-local-pvc-0 NAMESPACE=default \
#   bash apply-local-pvc-test-pod.sh

set -euo pipefail

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/pod-local-pvc-test.tpl.yaml"

TEST_POD_NAME="${TEST_POD_NAME:-local-ssd-test-pod}"
PVC_NAME="${PVC_NAME:-ssd-local-pvc-0}"
NAMESPACE="${NAMESPACE:-default}"

[ -f "$TEMPLATE_FILE" ] || { echo "ERROR: template not found: $TEMPLATE_FILE" >&2; exit 1; }
command -v envsubst >/dev/null || { echo "ERROR: envsubst 不存在,请先安装 gettext-base / gettext" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl 不存在" >&2; exit 1; }

echo "== manual local PV test pod render vars =="
echo "TEST_POD_NAME=$TEST_POD_NAME"
echo "PVC_NAME=$PVC_NAME"
echo "NAMESPACE=$NAMESPACE"

envsubst < "$TEMPLATE_FILE" | kubectl apply -f -
