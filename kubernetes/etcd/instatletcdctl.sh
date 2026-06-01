# 系统: Linux (systemd) + kubeadm 部署的 K8s 集群,主机上没装 etcdctl
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/etcd/instatletcdctl.sh
# 用法: curl -sLk <上面 URL> | bash

# 优先 Nexus 代理 GitHub release
wget --no-check-certificate \
  https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/etcd-io/etcd/releases/download/v3.5.18/etcd-v3.5.18-linux-amd64.tar.gz \
  || wget --no-check-certificate \
  https://chfs.sxxpqp.top:8443/chfs/shared/k8s/etcd/etcd-v3.5.18-linux-amd64.tar.gz
tar -xzf etcd-v3.5.18-linux-amd64.tar.gz -C /usr/local/bin/ --strip-components=1 etcd-v3.5.18-linux-amd64/etcdctl
etcdctl version