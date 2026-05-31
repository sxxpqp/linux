#/bin/bash
set -e
echo "开始安装 containerd ..."
# 下载所需应用包

wget -N https://chfs.sxxpqp.top:8443/chfs/shared/docker/containerd/cri-containerd-cni-1.7.18-linux-amd64.tar.gz
wget -N https://chfs.sxxpqp.top:8443/chfs/shared/docker/containerd/cni-plugins-linux-amd64-v1.5.1.tgz

# centos7 要升级libseccomp  runc二进制不需要这个包 静态编译了
# yum -y install https://mirrors.tuna.tsinghua.edu.cn/centos/8-stream/BaseOS/x86_64/os/Packages/libseccomp-2.5.1-1.el8.x86_64.rpm


# 创建cni插件所需目录
mkdir -p /etc/cni/net.d /opt/cni/bin 
# 解压cni二进制包
tar xf cni-plugins-linux-amd64-v*.tgz -C /opt/cni/bin/

# 解压
tar -xzf cri-containerd-cni-*-linux-amd64.tar.gz -C /
# 创建服务启动文件
cat > /etc/systemd/system/containerd.service <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF



# 创建Containerd的配置文件
mkdir -p /etc/containerd
cp /usr/local/bin/containerd /usr/bin/containerd
containerd config default | tee /etc/containerd/config.toml

# 修改Containerd的配置文件
sed -i "s#SystemdCgroup\ \=\ false#SystemdCgroup\ \=\ true#g" /etc/containerd/config.toml
cat /etc/containerd/config.toml | grep SystemdCgroup
sed -i "s#registry.k8s.io#registry.aliyuncs.com/google_containers#g" /etc/containerd/config.toml
cat /etc/containerd/config.toml | grep sandbox_image
sed -i "s#config_path\ \=\ \"\"#config_path\ \=\ \"/etc/containerd/certs.d\"#g" /etc/containerd/config.toml
cat /etc/containerd/config.toml | grep certs.d


# 配置加速器
mkdir /etc/containerd/certs.d/docker.io -pv
cat > /etc/containerd/certs.d/docker.io/hosts.toml << EOF
server = "https://docker.io"
[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
EOF


# 启动并设置为开机启动
systemctl daemon-reload
systemctl enable --now containerd.service
systemctl stop containerd.service
systemctl start containerd.service
systemctl restart containerd.service


cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
br_netfilter
EOF
modprobe br_netfilter


cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sysctl --system

wget -N  https://chfs.sxxpqp.top:8443/chfs/shared/docker/containerd/runc.amd64
chmod +x runc.amd64
# 覆盖 mv
mv -f runc.amd64 /usr/local/sbin/runc  
systemctl restart containerd.service
echo "containerd 安装完成"