#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/redis-cluster/install.sh
# 部署 KubeBlocks Redis Sharding Cluster (3 shard × 2 副本 = 6 pod).
# 仅 ClusterIP/Headless 访问 (cluster.yaml 里 NodePort 段已注释).
#
# 密码流程:
#   1) 先建 Secret (含 username=default + password=FIXED_PASS 两个 key, 缺一不可)
#   2) 再 apply Cluster, systemAccounts.secretRef 指向此 Secret → KubeBlocks 直接用它做 requirepass
#   3) --wait 模式下做密码轮换兜底 (个别版本 secretRef 仍随机生成密码时生效)
#
# 用法:
#   bash install.sh                          # 默认 ns=test, 密码=redis123
#   bash install.sh --ns prod --pass 'Xxx'
#   bash install.sh --wait                   # 等 Ready + 密码轮换兜底
#   REDIS_PASS=MyPass bash install.sh --wait
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
NS="test"
WAIT=false
SECRET_NAME="redis-cluster-password"
FIXED_PASS="${REDIS_PASS:-redis123}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)   NS="$2"; shift 2 ;;
    --wait) WAIT=true; shift ;;
    --pass) FIXED_PASS="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,9p' "$0" | sed 's/^# //'
      exit 0 ;;
    *)
      echo "未知参数: $1"; exit 1 ;;
  esac
done

# ---------- 前置 ----------
if ! kubectl get crd clusters.apps.kubeblocks.io &>/dev/null; then
  echo "ERROR: KubeBlocks operator 未安装, 先跑 bash ../install.sh"
  exit 1
fi

# ---------- 1. namespace ----------
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f -

# ---------- 2. 预创建 Secret (必须先于 Cluster!) ----------
# cluster.yaml 里 systemAccounts.secretRef 指向 ${SECRET_NAME}, 必须先存在,
# 否则 ComponentParameter reconciler 找不到 default credential, 报
#   "has no Credential object default found when resolving vars"
# 死循环, cluster 永远卡在 Creating.
#
# KubeBlocks v1 的 Credential 要求 Secret 同时有 username + password 两个 key.
echo "预创建 Secret/${SECRET_NAME} (username=default, password=${FIXED_PASS})..."
kubectl create secret generic "${SECRET_NAME}" -n "${NS}" \
  --from-literal=username=default \
  --from-literal=password="${FIXED_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo ""

# ---------- 3. 部署 Cluster ----------
echo "部署 Redis Cluster 到 namespace=${NS}..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/cluster.yaml" | kubectl apply -f -
echo ""

# ---------- 4. 部署稳定 Service ----------
echo "部署稳定 Service redis-cluster (名字固定, 不受 shard 后缀变化影响)..."
sed "s|namespace: test|namespace: ${NS}|" "${DIR}/stable-service.yaml" | kubectl apply -f -
echo ""

# ---------- 4. 等就绪 + 密码轮换 ----------
ACTUAL_PASS=""

if [ "$WAIT" = true ]; then
  echo "等 cluster.status.phase=Running (3-5 分钟)..."
  for i in $(seq 1 60); do
    STATUS=$(kubectl get cluster.apps.kubeblocks.io redis-cluster -n "${NS}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || true)
    echo "  [$i/60] phase=${STATUS:-<empty>}"
    [ "$STATUS" = "Running" ] && break
    [ "$STATUS" = "Failed" ] && { echo "  ✗ Failed"; break; }
    sleep 10
  done
  echo ""

  # 取 KubeBlocks 自动生成的密码
  SRC_SEC=$(kubectl get secret -n "${NS}" -l app.kubernetes.io/instance=redis-cluster -o name 2>/dev/null \
    | grep -i 'account-default' | head -1)
  if [ -n "$SRC_SEC" ]; then
    OLD_PASS=$(kubectl get -n "${NS}" "$SRC_SEC" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  fi

  if [ -z "${OLD_PASS:-}" ]; then
    echo "WARN: 取不到自动生成的密码, 跳过轮换"
  elif [ "$OLD_PASS" = "$FIXED_PASS" ]; then
    echo "密码已经是目标值, 跳过轮换"
    ACTUAL_PASS="$FIXED_PASS"
  else
    echo "把所有 redis pod 的密码轮换成固定值: ${FIXED_PASS}"
    NEW_B64=$(printf '%s' "$FIXED_PASS" | base64 | tr -d '\n')
    ROTATE_OK=true

    for pod in $(kubectl get pod -n "${NS}" -l app.kubernetes.io/instance=redis-cluster -o name 2>/dev/null); do
      POD_NAME=${pod#pod/}
      echo "  [$POD_NAME] CONFIG SET requirepass + masterauth + REWRITE"
      if ! kubectl exec -n "${NS}" "$POD_NAME" -c redis-cluster -- \
            redis-cli -a "$OLD_PASS" --no-auth-warning CONFIG SET requirepass "$FIXED_PASS" >/dev/null 2>&1; then
        echo "    ✗ requirepass 改失败"
        ROTATE_OK=false
        continue
      fi
      kubectl exec -n "${NS}" "$POD_NAME" -c redis-cluster -- \
        redis-cli -a "$FIXED_PASS" --no-auth-warning CONFIG SET masterauth "$FIXED_PASS" >/dev/null 2>&1 || true
      kubectl exec -n "${NS}" "$POD_NAME" -c redis-cluster -- \
        redis-cli -a "$FIXED_PASS" --no-auth-warning CONFIG REWRITE >/dev/null 2>&1 || true
    done

    if [ "$ROTATE_OK" = true ]; then
      for sec in $(kubectl get secret -n "${NS}" -l app.kubernetes.io/instance=redis-cluster -o name 2>/dev/null \
                   | grep -i 'account-default'); do
        kubectl patch -n "${NS}" "$sec" --type='merge' \
          -p "{\"data\":{\"password\":\"${NEW_B64}\"}}" >/dev/null
      done
      ACTUAL_PASS="$FIXED_PASS"
      echo "  ✓ 密码已固定"
    else
      echo "  ⚠ 部分 pod 改失败, 保持自动生成的密码"
      ACTUAL_PASS="$OLD_PASS"
    fi
  fi
  echo ""
fi

# 同步到固定名 Secret
if [ -n "$ACTUAL_PASS" ]; then
  echo "同步密码到 Secret/${SECRET_NAME}..."
  PASS_B64=$(printf '%s' "$ACTUAL_PASS" | base64 | tr -d '\n')
  USER_B64=$(printf '%s' 'default' | base64 | tr -d '\n')
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NS}
data:
  password: ${PASS_B64}
  username: ${USER_B64}
immutable: false
EOF
  echo ""
else
  echo "当前未轮换密码, 手动获取 KubeBlocks 自动生成的密码:"
  echo "  SRC=\$(kubectl get secret -n ${NS} -l app.kubernetes.io/instance=redis-cluster -o name | grep account-default | head -1)"
  echo "  PASS=\$(kubectl get -n ${NS} \$SRC -o jsonpath='{.data.password}' | base64 -d)"
  echo "  kubectl create secret generic ${SECRET_NAME} -n ${NS} --from-literal=password=\"\$PASS\""
fi

# ---------- 5. 连接信息汇总 ----------
echo ""
echo "==============================================================="
echo " ✓ 连接信息"
echo "==============================================================="

echo ""
echo "------- 密码 -------"
if [ -n "$ACTUAL_PASS" ]; then
  echo "  密码:       ${ACTUAL_PASS}"
else
  echo "  (密码还没轮换, 用上面的命令从自动生成的 Secret 取)"
fi
echo "  随时取用:   kubectl get secret ${SECRET_NAME} -n ${NS} -o jsonpath='{.data.password}' | base64 -d; echo"

echo ""
echo "------- 集群内访问 (从 K8s pod 内连) -------"
echo ""
echo "  ⭐ 业务代码用这个稳定地址:"
echo "      redis-cluster.${NS}.svc:6379"
echo ""

STABLE_EP=$(kubectl get endpoints redis-cluster -n "${NS}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
echo "  redis-cluster Service endpoints: ${STABLE_EP} (期望 6)"

if [ "${STABLE_EP}" -lt 6 ]; then
  echo ""
  echo "  ⚠ endpoints < 6, 检查 label 匹配:"
  echo "    kubectl get pod -n ${NS} -l app.kubernetes.io/instance=redis-cluster,apps.kubeblocks.io/sharding-name=shard -o name | wc -l"
fi

echo ""
echo "------- 一键验证 -------"
echo ""
echo "  POD=\$(kubectl get pod -n ${NS} -l app.kubernetes.io/instance=redis-cluster -o name | head -1)"
echo "  PASS=\$(kubectl get secret ${SECRET_NAME} -n ${NS} -o jsonpath='{.data.password}' | base64 -d)"
echo "  kubectl exec -n ${NS} \${POD#pod/} -c redis-cluster -- redis-cli -a \"\$PASS\" --no-auth-warning cluster info | head"
