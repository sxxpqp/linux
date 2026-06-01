# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/cert/k8s-cert-rotation.sh
# ============ 前置检查 ============
# 0. 确认 etcdctl 在主机上(kubeadm 默认不装,容器里有但主机没有)
if ! command -v etcdctl >/dev/null 2>&1; then
    echo "主机未装 etcdctl,执行以下命令安装后再回来跑:"
    echo "  wget https://chfs.sxxpqp.top:8443/chfs/shared/k8s/etcd/etcd-v3.5.18-linux-amd64.tar.gz"
    echo "  tar -xzf etcd-v3.5.18-linux-amd64.tar.gz -C /usr/local/bin/ --strip-components=1 etcd-v3.5.18-linux-amd64/etcdctl"
    echo "(或:bash kubernetes/etcd/instatletcdctl.sh)"
    exit 1
fi

# 1. 查看证书当前过期时间
kubeadm certs check-expiration

# 2. 备份现有证书 + 整个 /etc/kubernetes + etcd 快照(强烈建议!)
TS=$(date +%F-%H%M)
BAK=/root/cert-rotate-${TS}
mkdir -p ${BAK}

# 2.1 一把梭备份整个 /etc/kubernetes(pki/ + manifests/ + 所有 *.conf 全在里面)
cp -a /etc/kubernetes ${BAK}/etc-kubernetes
ls ${BAK}/etc-kubernetes/       # 应该看到 pki/ manifests/ admin.conf 等

# 2.2 etcd 快照(stacked etcd 在每台 master 上都跑一份;external etcd 在 etcd 节点跑)
export ETCDCTL_API=3
etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save ${BAK}/etcd-snapshot.db
# 2.3 校验快照(很关键,损坏的快照恢复不了)
etcdctl --write-out=table snapshot status ${BAK}/etcd-snapshot.db
# 期望:看到 HASH / REVISION / TOTAL KEYS / TOTAL SIZE 四列表格

# ============ 每个 master 节点执行 ============
# 3. 更新所有证书(只更新磁盘文件,不影响运行中的组件)
kubeadm certs renew all

# 4. 确认新证书已签发
kubeadm certs check-expiration

# 5. 更新 kubeconfig(重要!)
cp -f /etc/kubernetes/admin.conf /root/.kube/config

# ============ 逐台重启控制面组件(必须串行!)============
# 6. 本节点重启 apiserver、controller-manager、scheduler、etcd
# 用轮询代替死 sleep,实时打印进度,看得见在干嘛、还要等多久
cd /etc/kubernetes/manifests

# 工具函数:等容器消失 / 出现,带可视化进度
wait_container_gone() {        # $1=容器名关键字  $2=最长等待秒
    local name=$1 max=${2:-60} i=0
    while crictl ps -q --name "$name" 2>/dev/null | grep -q .; do
        i=$((i+1))
        [ $i -ge $max ] && { echo "  [TIMEOUT] $name 容器 ${max}s 内没停"; return 1; }
        printf "\r  [%02ds] 等待 %s 容器停止..." $i "$name"; sleep 1
    done
    printf "\r  [%02ds] %s 容器已停止     \n" $i "$name"
}
wait_container_up() {          # $1=容器名关键字  $2=最长等待秒
    local name=$1 max=${2:-90} i=0
    while ! crictl ps --name "$name" 2>/dev/null | grep -q Running; do
        i=$((i+1))
        [ $i -ge $max ] && { echo "  [TIMEOUT] $name 容器 ${max}s 内没起来,检查 crictl ps -a + journalctl -u kubelet"; return 1; }
        printf "\r  [%02ds] 等待 %s 容器拉起..." $i "$name"; sleep 1
    done
    printf "\r  [%02ds] %s 容器 Running   \n" $i "$name"
}
# etcd 专用:容器 Running 不等于加入集群,要 endpoint health 三家都 healthy 才算真的好
wait_etcd_cluster_healthy() {
    local max=${1:-180} i=0
    while true; do
        out=$(ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
              --cacert=/etc/kubernetes/pki/etcd/ca.crt \
              --cert=/etc/kubernetes/pki/etcd/server.crt \
              --key=/etc/kubernetes/pki/etcd/server.key \
              endpoint health --cluster 2>&1)
        healthy=$(echo "$out" | grep -c "is healthy")
        unhealthy=$(echo "$out" | grep -c "is unhealthy\|did not respond")
        if [ "$healthy" -eq 3 ] && [ "$unhealthy" -eq 0 ]; then
            printf "\r  [%02ds] etcd 集群 3/3 全 healthy ✓                \n" $i
            return 0
        fi
        i=$((i+1))
        [ $i -ge $max ] && { echo ""; echo "  [TIMEOUT] etcd ${max}s 内还没全部 healthy:"; echo "$out"; return 1; }
        printf "\r  [%02ds] etcd 集群 healthy: %s/3..." $i "$healthy"; sleep 1
    done
}

for f in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml; do
    name=$(basename $f .yaml | sed 's/^kube-//')   # apiserver / controller-manager / scheduler / etcd
    # etcd 给更长 timeout(WAL 回放 + peer 握手 + catch-up)
    [ "$name" = "etcd" ] && UP_TIMEOUT=180 || UP_TIMEOUT=90
    echo ""
    echo "==== [$(date +%T)] 处理 $f (容器名关键字: $name, 起容器最长等 ${UP_TIMEOUT}s) ===="
    echo "  [step 1/4] 移走 manifest,让 kubelet 停掉旧 pod"
    mv $f /tmp/$f
    wait_container_gone "$name" 60 || exit 1

    echo "  [step 2/4] 移回 manifest,让 kubelet 拉起新 pod(加载新证书)"
    mv /tmp/$f .
    wait_container_up "$name" $UP_TIMEOUT || exit 1

    echo "  [step 3/4] 再观察 5 秒,确保不是起来又挂"
    sleep 5
    crictl ps --name "$name" | grep -v CONTAINER || { echo "  [FAIL] $name 又掉了"; exit 1; }

    # etcd 额外:等三家都 healthy 才算真的完成
    if [ "$name" = "etcd" ]; then
        echo "  [step 3.5/4] 等 etcd 集群 3/3 healthy(WAL 回放 + 加入集群)..."
        wait_etcd_cluster_healthy 180 || exit 1
    fi

    echo "  [step 4/4] $f 完成 ✓"
done
echo ""
echo "==== [$(date +%T)] 4 个控制面 static pod 全部重建完成 ===="

# 7. 重启 kubelet 让它重新加载 kubelet.conf
systemctl restart kubelet

# 8. 验证本节点组件都 Ready
NODE=$(hostname)        # 如果 kubectl 里节点名跟 hostname 不一致,改成手动 NODE=master-1
kubectl get pod -n kube-system -o wide --field-selector spec.nodeName=${NODE}
kubectl get node ${NODE}

# ============ 等第一台完全恢复再操作下一台 ============
# 确认 APISERVER READY 后再去 master-2、master-3 重复上面步骤



