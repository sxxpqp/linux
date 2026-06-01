# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/cert/k8s-cert-rotation.sh
# ============ 前置检查 ============
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
cd /etc/kubernetes/manifests
for f in kube-apiserver.yaml kube-controller-manager.yaml kube-scheduler.yaml etcd.yaml; do
    mv $f /tmp/$f
    sleep 20
    mv /tmp/$f .
    sleep 30   # 等 pod 重建完
done

# 7. 重启 kubelet 让它重新加载 kubelet.conf
systemctl restart kubelet

# 8. 验证本节点组件都 Ready
NODE=$(hostname)        # 如果 kubectl 里节点名跟 hostname 不一致,改成手动 NODE=master-1
kubectl get pod -n kube-system -o wide --field-selector spec.nodeName=${NODE}
kubectl get node ${NODE}

# ============ 等第一台完全恢复再操作下一台 ============
# 确认 APISERVER READY 后再去 master-2、master-3 重复上面步骤



