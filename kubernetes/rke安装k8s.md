## 1. 在安装master、worker安装docker
```bash
curl https://releases.rancher.com/install-docker/20.10.sh | sh
systemctl enable docker
systemctl start docker
systemctl status docker
systemctl daemon-reload
```

## 2.在安装master、worker节点上添加docker的用户组，
```bash
useradd dockeruser
usermod -aG docker dockeruser
passwd dockeruser
```
## 3.在安装master、worker关闭防火墙
```bash
systemctl stop firewalld
systemctl disable firewalld
```
### 设置内核参数
```bash
cat >> /etc/sysctl.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sysctl -p
```

## 4.分别在master、worker设置hostname
```
hostnamectl set-hostname rke-master01
hostnamectl set-hostname rke-master02
hostnamectl set-hostname rke-master03
hostnamectl set-hostname rke-node01
hostnamectl set-hostname rke-node02
```

## 5. 在rke安装k8s
```bash
curl -sfL https://get.rke.dev | sh -
```

## 6. 设置hosts
```bash
cat >> /etc/hosts <<EOF
192.168.1.46 rke-master01
192.168.1.52 rke-master02
192.168.1.53 rke-master03
192.168.1.55    rke-node01
192.168.1.56    rke-node02
EOF
```

##  7. ssh免密登录
```bash
ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa
ssh-copy-id dockeruser@rke-master01
ssh-copy-id dockeruser@rke-master02
ssh-copy-id dockeruser@rke-master03
ssh-copy-id dockeruser@rke-node01
ssh-copy-id dockeruser@rke-node02
```

## 8. 创建集群配置文件
```bash
cat > cluster.yml <<EOF
nodes:
- address: 192.168.1.46
  port: "22"
  internal_address: ""
  role:
  - controlplane
  - worker
  - etcd
  hostname_override: rke-master01
  user: dockeruser
  docker_socket: /var/run/docker.sock
  ssh_key: ""
  ssh_key_path: ~/.ssh/id_rsa
  ssh_cert: ""
  ssh_cert_path: ""
  labels: {}
  taints: []
- address: 192.168.1.52
  port: "22"
  internal_address: ""
  role:
  - controlplane
  - worker
  - etcd
  hostname_override: rke-master02
  user: dockeruser
  docker_socket: /var/run/docker.sock
  ssh_key: ""
  ssh_key_path: ~/.ssh/id_rsa
  ssh_cert: ""
  ssh_cert_path: ""
  labels: {}
  taints: []
- address: 192.168.1.53
  port: "22"
  internal_address: ""
  role:
  - controlplane
  - worker
  - etcd
  hostname_override: rke-master03
  user: dockeruser
  docker_socket: /var/run/docker.sock
  ssh_key: ""
  ssh_key_path: ~/.ssh/id_rsa
  ssh_cert: ""
  ssh_cert_path: ""
  labels: {}
  taints: []
- address: 192.168.1.55
  port: "22"
  internal_address: ""
  role:
  - worker
  hostname_override: rke-node01
  user: dockeruser
  docker_socket: /var/run/docker.sock
  ssh_key: ""
  ssh_key_path: ~/.ssh/id_rsa
  ssh_cert: ""
  ssh_cert_path: ""
  labels: {}
  taints: []
- address: 192.168.1.56
  port: "22"
  internal_address: ""
  role:
  - worker
  hostname_override: rke-node02
  user: dockeruser
  docker_socket: /var/run/docker.sock
  ssh_key: ""
  ssh_key_path: ~/.ssh/id_rsa
  ssh_cert: ""
  ssh_cert_path: ""
  labels: {}
  taints: []
services:
  etcd:
    image: ""
    extra_args: {}
    extra_args_array: {}
    extra_binds: []
    extra_env: []
    win_extra_args: {}
    win_extra_args_array: {}
    win_extra_binds: []
    win_extra_env: []
    external_urls: []
    ca_cert: ""
    cert: ""
    key: ""
    path: ""
    uid: 0
    gid: 0
    snapshot: true
    retention: "6h"
    creation: "24h"
    backup_config: null
  kube-api:
    image: ""
    extra_args: {}
    extra_args_array: {}
    extra_binds: []
    extra_env: []
    win_extra_args: {}
    win_extra_args_array: {}
    win_extra_binds: []
    win_extra_env: []
    service_cluster_ip_range: 10.43.0.0/16
    service_node_port_range: ""
    pod_security_policy: false
    always_pull_images: false
    secrets_encryption_config: null
    audit_log: null
    admission_configuration: null
    event_rate_limit: null
  kube-controller:
    image: ""
    extra_args: {}
    extra_args_array: {}
    extra_binds: []
    extra_env: []
    win_extra_args: {}
    win_extra_args_array: {}
    win_extra_binds: []
    win_extra_env: []
    cluster_cidr: 10.42.0.0/16
    service_cluster_ip_range: 10.43.0.0/16
  scheduler:
    image: ""
    extra_args: {}
    extra_args_array: {}
    extra_binds: []
    extra_env: []
    win_extra_args: {}
    win_extra_args_array: {}
    win_extra_binds: []
    win_extra_env: []
  kubelet:
    image: ""
    extra_args: {}
    extra_args_array: {}
    extra_binds: []
    extra_env: []
    win_extra_args: {}
    win_extra_args_array: {}
    win_extra_binds: []
    win_extra_env: []
    cluster_domain: cluster.local
    infra_container_image: ""
    cluster_dns_server: 10.43.0.10
    fail_swap_on: false
    generate_serving_certificate: false
  kubeproxy:
    image: ""
    extra_args: {}
    extra_args_array: {}
    extra_binds: []
    extra_env: []
    win_extra_args: {}
    win_extra_args_array: {}
    win_extra_binds: []
    win_extra_env: []
network:
  plugin: canal
  options: {}
  mtu: 0
  node_selector: {}
  update_strategy: null
  tolerations: []
authentication:
  strategy: x509
  sans: []
  webhook: null
addons: ""
addons_include: []
system_images:
  etcd: rancher/mirrored-coreos-etcd:v3.5.4
  alpine: rancher/rke-tools:v0.1.88
  nginx_proxy: rancher/rke-tools:v0.1.88
  cert_downloader: rancher/rke-tools:v0.1.88
  kubernetes_services_sidecar: rancher/rke-tools:v0.1.88
  kubedns: rancher/mirrored-k8s-dns-kube-dns:1.21.1
  dnsmasq: rancher/mirrored-k8s-dns-dnsmasq-nanny:1.21.1
  kubedns_sidecar: rancher/mirrored-k8s-dns-sidecar:1.21.1
  kubedns_autoscaler: rancher/mirrored-cluster-proportional-autoscaler:1.8.5
  coredns: rancher/mirrored-coredns-coredns:1.9.3
  coredns_autoscaler: rancher/mirrored-cluster-proportional-autoscaler:1.8.5
  nodelocal: rancher/mirrored-k8s-dns-node-cache:1.21.1
  kubernetes: rancher/hyperkube:v1.24.10-rancher4
  flannel: rancher/mirrored-coreos-flannel:v0.15.1
  flannel_cni: rancher/flannel-cni:v0.3.0-rancher6
  calico_node: rancher/mirrored-calico-node:v3.22.5
  calico_cni: rancher/calico-cni:v3.22.5-rancher1
  calico_controllers: rancher/mirrored-calico-kube-controllers:v3.22.5
  calico_ctl: rancher/mirrored-calico-ctl:v3.22.5
  calico_flexvol: rancher/mirrored-calico-pod2daemon-flexvol:v3.22.5
  canal_node: rancher/mirrored-calico-node:v3.22.5
  canal_cni: rancher/calico-cni:v3.22.5-rancher1
  canal_controllers: rancher/mirrored-calico-kube-controllers:v3.22.5
  canal_flannel: rancher/mirrored-flannelcni-flannel:v0.17.0
  canal_flexvol: rancher/mirrored-calico-pod2daemon-flexvol:v3.22.5
  weave_node: weaveworks/weave-kube:2.8.1
  weave_cni: weaveworks/weave-npc:2.8.1
  pod_infra_container: rancher/mirrored-pause:3.6
  ingress: rancher/nginx-ingress-controller:nginx-1.5.1-rancher2
  ingress_backend: rancher/mirrored-nginx-ingress-controller-defaultbackend:1.5-rancher1
  ingress_webhook: rancher/mirrored-ingress-nginx-kube-webhook-certgen:v1.1.1
  metrics_server: rancher/mirrored-metrics-server:v0.6.2
  windows_pod_infra_container: rancher/mirrored-pause:3.6
  aci_cni_deploy_container: noiro/cnideploy:5.2.3.5.1d150da
  aci_host_container: noiro/aci-containers-host:5.2.3.5.1d150da
  aci_opflex_container: noiro/opflex:5.2.3.5.1d150da
  aci_mcast_container: noiro/opflex:5.2.3.5.1d150da
  aci_ovs_container: noiro/openvswitch:5.2.3.5.1d150da
  aci_controller_container: noiro/aci-containers-controller:5.2.3.5.1d150da
  aci_gbp_server_container: noiro/gbp-server:5.2.3.5.1d150da
  aci_opflex_server_container: noiro/opflex-server:5.2.3.5.1d150da
ssh_key_path: ~/.ssh/id_rsa
ssh_cert_path: ""
ssh_agent_auth: false
authorization:
  mode: rbac
  options: {}
ignore_docker_version: null
enable_cri_dockerd: null
kubernetes_version: ""
private_registries: []
ingress:
  provider: ""
  options: {}
  node_selector: {}
  extra_args: {}
  dns_policy: ""
  extra_envs: []
  extra_volumes: []
  extra_volume_mounts: []
  update_strategy: null
  http_port: 0
  https_port: 0
  network_mode: ""
  tolerations: []
  default_backend: null
  default_http_backend_priority_class_name: ""
  nginx_ingress_controller_priority_class_name: ""
  default_ingress_class: null
cluster_name: ""
cloud_provider:
  name: ""
prefix_path: ""
win_prefix_path: ""
addon_job_timeout: 0
bastion_host:
  address: ""
  port: ""
  user: ""
  ssh_key: ""
  ssh_key_path: ""
  ssh_cert: ""
  ssh_cert_path: ""
  ignore_proxy_env_vars: false
monitoring:
  provider: ""
  options: {}
  node_selector: {}
  update_strategy: null
  replicas: null
  tolerations: []
  metrics_server_priority_class_name: ""
restore:
  restore: false
  snapshot_name: ""
rotate_encryption_key: false
dns: null
EOF
```
## 9.启动集群

```bash
rke up
```
