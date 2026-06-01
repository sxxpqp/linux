# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/kind/deploy.sh
cat > kind-config.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
- role: worker
- role: worker
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
EOF

kind create cluster --name kind --config=kind-config.yaml

# 对每个节点执行
for node in $(kind get nodes --name kind); do
  docker exec -i $node bash << 'SCRIPT'
  # 创建 docker.io 加速配置目录
  mkdir -p /etc/containerd/certs.d/docker.io
  cat > /etc/containerd/certs.d/docker.io/hosts.toml << 'TOML'
server = "https://registry-1.docker.io"

[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
TOML
# 创建 ghcr.io 加速配置
  mkdir -p /etc/containerd/certs.d/ghcr.io
  cat > /etc/containerd/certs.d/ghcr.io/hosts.toml << 'TOML'
server = "https://ghcr.io"

[host."https://ghcr.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
TOML
  mkdir -p /etc/containerd/certs.d/registry.k8s.io
  cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml << 'TOML'
server = "https://registry.k8s.io"

[host."https://k8s.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
TOML
  mkdir -p /etc/containerd/certs.d/quay.io
  cat > /etc/containerd/certs.d/quay.io/hosts.toml << 'TOML'
server = "https://quay.io"

[host."https://quay.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
TOML
  # 重启 containerd 使配置生效
  systemctl restart containerd
SCRIPT
done

# 验证配置生效
docker exec kind-control-plane cat /etc/containerd/certs.d/docker.io/hosts.toml