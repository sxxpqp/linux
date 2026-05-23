# kubeadm 集群部署

kubeadm 部署高可用 K8s 集群、离线安装、内核优化、备份恢复。

## 文件说明

| 文件/目录 | 说明 |
|---|---|
| [installk8s.sh](installk8s.sh) | kubeadm 自动化安装 K8s 脚本 |
| [k8s-setup-menu.sh](k8s-setup-menu.sh) | 菜单式 K8s 集群部署脚本 |
| [k8skerneloptimize.sh](k8skerneloptimize.sh) | K8s 节点内核参数优化脚本 |
| [kubeadm-ha-cluster.md](kubeadm-ha-cluster.md) | kubeadm 高可用集群部署文档 |
| [offline-install-k8s.md](offline-install-k8s.md) | 离线安装 K8s 集群指南 |
| [restorandchangevip/](restorandchangevip/) | VIP 切换与恢复配置（kube-vip + kubeadm-config） |
| [restore/](restore/) | etcd 备份恢复文档与 kubeadm-config |
