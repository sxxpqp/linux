#!/usr/bin/env bash
# 系统: 管理机渲染并 apply manual local PV 模板(StorageClass + PV + PVC)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/local-pv-manual/apply-local-ssd-template.sh
# 用法: curl -sL <URL> -o apply-local-ssd-template.sh && bash apply-local-ssd-template.sh [变量覆盖]
#
# 默认值说明:
#   - 不传环境变量时,使用下面的默认值
#   - 需要新建别的 PVC/PV/目录时,直接 export 覆盖后再执行即可
#
# 示例:
#   bash apply-local-ssd-template.sh
#   STORAGE_CLASS_NAME=local-mysql PV_NAME=local-pv-mysql-node1 PVC_NAME=mysql-local-pvc-0 \
#   NAMESPACE=mysql PV_SIZE=200Gi LOCAL_PATH=/DATA/mysql/mysql-0 NODE_NAME=node1 \
#   bash apply-local-ssd-template.sh

set -euo pipefail

export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_FILE="${SCRIPT_DIR}/sc-pv-pvc-local-ssd.tpl.yaml"

STORAGE_CLASS_NAME="${STORAGE_CLASS_NAME:-local-ssd}"
PV_NAME="${PV_NAME:-local-pv-ssd-node1}"
PVC_NAME="${PVC_NAME:-ssd-local-pvc-0}"
NAMESPACE="${NAMESPACE:-default}"
PV_SIZE="${PV_SIZE:-200Gi}"
LOCAL_PATH="${LOCAL_PATH:-/mnt/disks/ssd1/ssd}"
NODE_NAME="${NODE_NAME:-node4}"

[ -f "$TEMPLATE_FILE" ] || { echo "ERROR: template not found: $TEMPLATE_FILE" >&2; exit 1; }
command -v envsubst >/dev/null || { echo "ERROR: envsubst 不存在,请先安装 gettext-base / gettext" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl 不存在" >&2; exit 1; }

echo "== manual local PV render vars =="
echo "STORAGE_CLASS_NAME=$STORAGE_CLASS_NAME"
echo "PV_NAME=$PV_NAME"
echo "PVC_NAME=$PVC_NAME"
echo "NAMESPACE=$NAMESPACE"
echo "PV_SIZE=$PV_SIZE"
echo "LOCAL_PATH=$LOCAL_PATH"
echo "NODE_NAME=$NODE_NAME"

envsubst < "$TEMPLATE_FILE" | kubectl apply -f -
