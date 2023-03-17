rke2高可用部署
1. 系统配置优化
```
# 关闭防火墙
systemctl stop firewalld
systemctl disable firewalld

# 关闭selinux
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

# 关闭swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 关闭ipv6
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl --system

# 关闭系统自动更新
systemctl stop packagekit
systemctl disable packagekit

# 开启ipvs
cat <<EOF > /etc/sysconfig/modules/ipvs.modules
#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack_ipv4
modprobe -- br_netfilter
EOF
chmod +x /etc/sysconfig/modules/ipvs.modules
bash /etc/sysconfig/modules/ipvs.modules

# 安装依赖
yum install -y yum-utils device-mapper-persistent-data lvm2 ipvsadm conntrack ntpdate ntp ipset jq iptables curl sysstat libseccomp wget vim net-tools git iptables-services bash-completion chrony conntrack-tools ipvsadm libseccomp libtool-ltdl rsync socat 

```
2.  下载rke2
```bash
curl -sfL https://rancher-mirror.rancher.cn/rke2/install.sh | INSTALL_RKE2_MIRROR=cn INSTALL_RKE2_CHANNEL=v1.20 sh - 
```
3.  配置rke2
```bash
mkdir -p /etc/rancher/rke2
cat <<EOF > /etc/rancher/rke2/config.yaml
write-kubeconfig-mode: "644"
token: my-shared-secret
tls-san:
  - rke2.sxxpqp.top
server: https://rke2.sxxpqp.top:9345  
EOF
```
4.  启动rke2
```bash
systemctl enable rke2-server
systemctl start rke2-server
```
5.  配置rke2的高可用
```bash
mkdir -p /etc/rancher/rke2
cat <<EOF > /etc/rancher/rke2/config.yaml
write-kubeconfig-mode: "644"
token: my-shared-secret
tls-san:
  - rke2.sxxpqp.top
server: https://rke2.sxxpqp.top:9345
EOF
```
6.  配置rke2的高可用
```bash
mkdir -p /etc/rancher/rke2
cat <<EOF > /etc/rancher/rke2/config.yaml
write-kubeconfig-mode: "644"
token: my-shared-secret
tls-san:
  - rke2.sxxpqp.top
server: https://rke2.sxxpqp.top:9345
EOF
```


7.  配置rke2的worker节点

```bash
mkdir -p /etc/rancher/rke2
cat <<EOF > /etc/rancher/rke2/config.yaml
write-kubeconfig-mode: "644"
token: my-shared-secret
tls-san:
  - rke2.sxxpqp.top
server: https://rke2.sxxpqp.top:9345
EOF
```
8. 安装rke2的worker节点
```bash
curl -sfL https://rancher-mirror.rancher.cn/rke2/install.sh | INSTALL_RKE2_MIRROR=cn 
INSTALL_RKE2_TYPE="agent" sh - 
```


8.  启动rke2的worker节点
```bash
systemctl enable rke2-server
systemctl start rke2-server
```

