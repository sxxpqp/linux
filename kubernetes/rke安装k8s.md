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
useradd rancher
usermod -aG docker rancher
passwd rancher
```
## 3.在安装master、worker关闭防火墙
```bash
systemctl stop firewalld
systemctl disable firewalld
```
### 设置内核参数
```bash
cat >> /etc/sysctl.conf <<EOF
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sysctl -p
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
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

## 6. 需要在rke、master、node设置hosts
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
ssh-copy-id rancher@rke-master01
ssh-copy-id rancherr@rke-master02
ssh-copy-id rancher@rke-master03
ssh-copy-id rancher@rke-node01
ssh-copy-id rancher@rke-node02
```

## 8. 创建集群配置文件
```bash
cat > cluster.yml <<EOF
EOF
```
## 9.启动集群

```bash
rke up
```
