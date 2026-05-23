 ./longhornctl-linux-amd64  check    preflight --kubeconfig=/etc/kubernetes/admin.conf 



 helm repo add longhorn https://nexus.ihome.sxxpqp.top:8443/repository/hwlm-longhorn/

 helm repo update


 helm install longhorn longhorn/longhorn --namespace longhorn-system --create-namespace --version 1.11.0