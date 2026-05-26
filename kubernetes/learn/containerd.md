
sandbox_image = "registry.aliyuncs.com/google_containers/pause:3.2"
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."registry.k8s.io"]
  endpoint = ["https://registry.aliyuncs.com/google_containers"]

# 创建Containerd的配置文件
```
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml
```
# 修改Containerd的配置文件
```
sed -i "s#SystemdCgroup\ \=\ false#SystemdCgroup\ \=\ true#g" /etc/containerd/config.toml
cat /etc/containerd/config.toml | grep SystemdCgroup
sed -i "s#registry.k8s.io#egistry.aliyuncs.com/google_containers#g" /etc/containerd/config.toml
cat /etc/containerd/config.toml | grep sandbox_image
sed -i "s#config_path\ \=\ \"\"#config_path\ \=\ \"/etc/containerd/certs.d\"#g" /etc/containerd/config.toml
cat /etc/containerd/config.toml | grep certs.d
```
# 配置加速器
```
mkdir /etc/containerd/certs.d/docker.io -pv
cat > /etc/containerd/certs.d/docker.io/hosts.toml << EOF
server = "https://docker.io"
[host."https://dockerproxy.1panel.live"]
  capabilities = ["pull", "resolve"]
[host."https://dockerhub20250301.sxxpqp.top"]
  capabilities = ["pull", "resolve"]  
EOF
```
# 启动并设置为开机启动
```
systemctl daemon-reload
systemctl enable --now containerd.service
systemctl stop containerd.service
systemctl start containerd.service
systemctl restart containerd.service
systemctl status containerd.service
```