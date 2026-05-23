# kubelet

kubelet 配置（systemd service + kubeadm dropin）。

## 文件说明

| 文件 | 说明 |
|---|---|
| [10-kubeadm.conf](10-kubeadm.conf) | kubelet systemd dropin 配置：kubeadm 生成的 KUBELET_KUBEADM_ARGS 动态参数、kubeconfig/kubeadm-config 配置 |
| [kubelet.service](kubelet.service) | kubelet systemd 服务单元 |
