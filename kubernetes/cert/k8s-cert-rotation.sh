# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/cert/k8s-cert-rotation.sh
# ============ 前置检查 ============
# 1. 查看证书当前过期时间
kubeadm certs check-expiration

# 2. 备份现有证书(强烈建议!)
cp -r /etc/kubernetes/pki /etc/kubernetes/pki.bak.$(date +%Y%m%d)
cp /etc/kubernetes/*.conf /etc/kubernetes/backup-$(date +%Y%m%d)/

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
kubectl get pod -n kube-system -o wide | grep <本节点名>
kubectl get node <本节点名>

# ============ 等第一台完全恢复再操作下一台 ============
# 确认 APISERVER READY 后再去 master-2、master-3 重复上面步骤



