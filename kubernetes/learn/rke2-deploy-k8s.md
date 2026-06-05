# RKE2 高可用部署

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/learn/rke2-deploy-k8s.md
> 状态: 学习笔记

3 master + 1 worker 的 RKE2 集群部署,镜像走阿里云加速。

## 拓扑

| 角色 | IP | hostname |
|---|---|---|
| Master 01(引导节点) | 192.168.1.57 | rke2-master01 |
| Master 02 | 192.168.1.58 | rke2-master02 |
| Master 03 | 192.168.1.59 | rke2-master03 |
| Worker | 192.168.1.60 | rke2-node01 |

---

## 一、系统配置优化(所有节点都执行)

```bash
# 关闭防火墙
systemctl stop firewalld
systemctl disable firewalld

# 关闭 SELinux
setenforce 0
sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

# 关闭 swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 关闭 IPv6 + 开启 forwarding
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

# 开启 IPVS
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

---

## 二、Master 01(引导节点)

### 1. 设置 hostname

```bash
hostnamectl set-hostname rke2-master01
```

### 2. 下载 RKE2

```bash
curl -sfL https://rancher-mirror.rancher.cn/rke2/install.sh \
  | INSTALL_RKE2_MIRROR=cn INSTALL_RKE2_CHANNEL=v1.20 sh -
```

### 3. 配置 RKE2

```bash
mkdir -p /etc/rancher/rke2
cat <<EOF > /etc/rancher/rke2/config.yaml
token: demo-server
node-name: rke2-master01
tls-san: 192.168.1.57
system-default-registry: "registry.cn-hangzhou.aliyuncs.com"
EOF
```

### 4. 启动 RKE2

```bash
systemctl enable rke2-server
systemctl start rke2-server
systemctl status rke2-server
journalctl -u rke2-server -f
```

### 5. kubectl 重定向到 RKE2

```bash
mkdir -p ~/.kube/
cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
ln -s /var/lib/rancher/rke2/bin/kubectl /usr/bin/kubectl
ln -s /var/lib/rancher/rke2/bin/ctr     /usr/bin/ctr
ln -s /var/lib/rancher/rke2/bin/crictl  /usr/bin/crictl
```

---

## 三、Master 02 / 03(加入集群)

两台机器步骤一致,只改 hostname。

### 1. 设置 hostname

```bash
hostnamectl set-hostname rke2-master02   # 第三台改 master03
```

### 2. 配置 RKE2(指向 Master 01 加入)

```bash
mkdir -p /etc/rancher/rke2
cat <<EOF > /etc/rancher/rke2/config.yaml
write-kubeconfig-mode: "644"
token: demo-server
tls-san:
  - 192.168.1.58
server: https://192.168.1.57:9345
EOF
```

### 3. 下载 + 启动

```bash
curl -sfL https://rancher-mirror.rancher.cn/rke2/install.sh \
  | INSTALL_RKE2_MIRROR=cn INSTALL_RKE2_CHANNEL=v1.20 sh -

systemctl enable rke2-server
systemctl start rke2-server
systemctl status rke2-server
journalctl -u rke2-server -f
```

---

## 四、Worker 节点

### 1. 设置 hostname

```bash
hostnamectl set-hostname rke2-node01
```

### 2. 配置

```bash
mkdir -p /etc/rancher/rke2
cat <<EOF > /etc/rancher/rke2/config.yaml
write-kubeconfig-mode: "644"
token: demo-server
tls-san:
  - 192.168.1.60
server: https://192.168.1.57:9345
EOF
```

### 3. 安装(注意 `INSTALL_RKE2_TYPE="agent"`)

```bash
curl -sfL https://rancher-mirror.rancher.cn/rke2/install.sh \
  | INSTALL_RKE2_MIRROR=cn INSTALL_RKE2_TYPE="agent" sh -
```

### 4. 启动 agent

```bash
systemctl enable rke2-agent
systemctl start rke2-agent
systemctl status rke2-agent
```

---

## 常见问题

### 6443 端口访问不通

防火墙规则多,直接放行 6443:

```bash
iptables -I INPUT -p tcp --dport 6443 -j ACCEPT
iptables-save
```
