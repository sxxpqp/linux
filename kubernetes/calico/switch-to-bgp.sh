# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/calico/switch-to-bgp.sh
kubectl edit ippools.crd.projectcalico.org default-ipv4-ippool

calicoctl get bgpconfiguration default -o yaml

calicoctl get bgpconfiguration default -o yaml
