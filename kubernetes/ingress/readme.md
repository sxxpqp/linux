# 配置加速器 
mkdir /etc/containerd/certs.d/registry.k8s.io -pv
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml << EOF
server = "https://registry.k8s.io"
[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
EOF

# 那些节点使用ingress 
kubectl lable node node1  ingress="true"

