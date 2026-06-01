#!/bin/bash
# 系统: Linux (systemd) + kubeadm 部署的单 master K8s 集群
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/cert/k8s-cert-rotation-single.sh
# 用法: bash k8s-cert-rotation-single.sh
# 用途: 单 master 测试集群上验证证书轮换脚本逻辑;生产 3 master 请用 k8s-cert-rotation.sh
# 文档: kubernetes/cert/k8s-cert-rotation-single-master.md

set -o errexit
set -o nounset
set -o pipefail

# ============ 配置 ============
TS=$(date +%F-%H%M)
BAK=/root/cert-rotate-${TS}
ETCD_OPTS="--endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

echo "==== [$(date +%T)] 单节点证书轮换开始,备份目录:${BAK} ===="

# ============ 1. 前置检查 ============
echo ""
echo "==== [1/6] 前置检查 ===="
[ -f /etc/kubernetes/manifests/etcd.yaml ] || { echo "未发现 stacked etcd,本脚本不适用"; exit 1; }
[ "$(kubectl get node -l node-role.kubernetes.io/control-plane --no-headers 2>/dev/null | wc -l)" = "1" ] \
    || { echo "检测到多 master,请用 k8s-cert-rotation.sh / 3masters.md"; exit 1; }
kubeadm certs check-expiration

# ============ 2. 备份 ============
echo ""
echo "==== [2/6] 备份 ===="
mkdir -p ${BAK}
cp -a /etc/kubernetes ${BAK}/etc-kubernetes
echo "  ✓ /etc/kubernetes 已备份"

export ETCDCTL_API=3
etcdctl ${ETCD_OPTS} snapshot save ${BAK}/etcd-snapshot.db
etcdctl --write-out=table snapshot status ${BAK}/etcd-snapshot.db
echo "  ✓ etcd 快照已校验"
ls -lh ${BAK}/

# ============ 3. 续证书 ============
echo ""
echo "==== [3/6] 续证书 ===="
kubeadm certs renew all
kubeadm certs check-expiration
cp -f /etc/kubernetes/admin.conf /root/.kube/config
echo "  ✓ 证书已续,kubeconfig 已更新"

# ============ 4. 重启 static pod ============
echo ""
echo "==== [4/6] 重启 4 个 static pod(轮询进度)===="
cd /etc/kubernetes/manifests

wait_container_gone() {
    local name=$1 max=${2:-60} i=0
    while crictl ps -q --name "$name" 2>/dev/null | grep -q .; do
        i=$((i+1))
        [ $i -ge $max ] && { echo ""; echo "  [TIMEOUT] $name 没停"; return 1; }
        printf "\r  [%02ds] 等待 %s 停止..." $i "$name"; sleep 1
    done
    printf "\r  [%02ds] %s 已停止     \n" $i "$name"
}
wait_container_up() {
    local name=$1 max=${2:-90} i=0
    while ! crictl ps --name "$name" 2>/dev/null | grep -q Running; do
        i=$((i+1))
        [ $i -ge $max ] && { echo ""; echo "  [TIMEOUT] $name 没起来,查 crictl ps -a + journalctl -u kubelet"; return 1; }
        printf "\r  [%02ds] 等待 %s 拉起..." $i "$name"; sleep 1
    done
    printf "\r  [%02ds] %s Running    \n" $i "$name"
}
wait_etcd_single_healthy() {
    local max=${1:-180} i=0
    while true; do
        if etcdctl ${ETCD_OPTS} endpoint health 2>&1 | grep -q "is healthy"; then
            printf "\r  [%02ds] etcd 1/1 healthy ✓     \n" $i
            return 0
        fi
        i=$((i+1))
        [ $i -ge $max ] && { echo ""; echo "  [TIMEOUT] etcd ${max}s 没恢复"; return 1; }
        printf "\r  [%02ds] 等 etcd 启动 / WAL 回放..." $i; sleep 1
    done
}

for f in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml; do
    name=$(basename $f .yaml | sed 's/^kube-//')
    [ "$name" = "etcd" ] && UP_TIMEOUT=180 || UP_TIMEOUT=90
    echo ""
    echo "  ---- 处理 $f (timeout ${UP_TIMEOUT}s) ----"
    mv $f /tmp/$f
    wait_container_gone "$name" 60
    mv /tmp/$f .
    wait_container_up "$name" $UP_TIMEOUT
    sleep 5
    crictl ps --name "$name" | grep -v CONTAINER >/dev/null || { echo "  [FAIL] $name 又掉了"; exit 1; }
    [ "$name" = "etcd" ] && wait_etcd_single_healthy 180
    echo "  ✓ $f 完成"
done

# ============ 5. 重启 kubelet ============
echo ""
echo "==== [5/6] 重启 kubelet ===="
systemctl restart kubelet
sleep 5
systemctl is-active kubelet
echo "  ✓ kubelet active"

# ============ 6. 验证 ============
echo ""
echo "==== [6/6] 验证 ===="
NODE=$(hostname)

echo "  → 节点状态:"
kubectl get node $NODE

echo ""
echo "  → 控制面 4 个 Pod:"
kubectl get pod -n kube-system -o wide --field-selector spec.nodeName=$NODE \
  | grep -E 'apiserver|controller-manager|scheduler|etcd' || true

echo ""
echo "  → etcd 状态:"
etcdctl ${ETCD_OPTS} endpoint status -w table
etcdctl ${ETCD_OPTS} endpoint health

echo ""
echo "  → 新证书过期时间(从 TCP 端口取):"
for port in 6443 2379 2380; do
    notafter=$(echo | openssl s_client -connect 127.0.0.1:$port 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    echo "    :${port} → notAfter = ${notafter}"
done

echo ""
echo "  → 异常 Pod(应该为空):"
kubectl get pod -A | grep -vE 'Running|Completed|NAMESPACE' || echo "    (无)"

echo ""
echo "==== [$(date +%T)] 全部完成 ✓  备份:${BAK} ===="
echo "如需回滚,见 kubernetes/cert/k8s-cert-rotation-single-master.md 第五节"
