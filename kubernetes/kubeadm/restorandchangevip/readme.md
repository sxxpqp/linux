# 单节点master集群  扩容到3节点并负载均衡地址不变
已有集群
k8s-node1=172.16.0.190
k8s-node2=172.16.0.189


# 获取master的hostname 这次是k8s-node1
# 备份etcd 通过etcd-backup.sh 
# 备份pki/ca.crt  pki/ca.key   
# tar -zcvf pki.tar.gz pki/ca.crt pki/ca.key
# 获取kubeadm-config.yaml 
# kubectl -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > kubeadm-config.yaml
# 获取etcd名称 
# kubectl get pod -n kube-system -o wide | grep etcd


# 新的节点设置
## hosts
hostnamectl set-hostname k8s-node1
#
ip a == 172.16.0.191
# 确保你的主机名能解析到本地，否则 API Server 拉不起来
echo "172.16.0.191 k8s-node1" >> /etc/hosts
# 通过etcdctl 恢复数据 到 新节点 172.16.0.191
etcd-restore.sh
# 解压pki  ca key 只需要根ca key
tar -zxvf pki.tar.gz  -C /etc/kubernetes/pki
## 使用kube-vip 配置负载均衡 172.16.0.190
wget https://chfs.sxxpqp.top:8443/chfs/shared/k8s/kubeadm/restorandchangevip/kube-vip.yaml

# 初始化
# kubectl -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > kubeadm.yaml
# 需要加san 
kubeadm init --config=kubeadm-config.yaml \
  --ignore-preflight-errors=DirAvailable--etc-kubernetes-pki,DirAvailable--var-lib-etcd 


# mv /etc/kubernetes/pki/apiserver.{crt,key} /opt
# kubeadm init phase certs apiserver --config=kubeadm-config.yaml

# 备份并移动 manifest 文件
# sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
# sleep 5 # 等待 kubelet 终止 Pod
# 移回 manifest 文件，kubelet 会自动创建新的 Pod
# sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
# sleep 5 # 等待新 Pod 启动

## 先获取 certificate-key 和 上传
kubeadm init phase upload-certs --upload-certs

# kubeadm certs certificate-key 拼接到 kubaadm join 
kubeadm join 172.16.0.190:6443 --token 7wob1v.ila456m799xql6ag         --discovery-token-ca-cert-hash sha256:e3dca016e7e18f43a6c3db3781338f68034b8209e5ceb28225c48167a00df0ef         --control-plane  --certificate-key 03dcb453cfa2fbf312c3367bca5e22af26feee044a6724089969e52276734722