## 2.1.所有k8s节点安装Containerd作为Runtime
```bash
#wget https://github.com/containernetworking/plugins/releases/download/v1.1.1/cni-plugins-linux-amd64-v1.1.1.tgz
#创建cni插件所需目录
mkdir -p /etc/cni/net.d /opt/cni/bin 
#解压cni二进制包
tar xf cni-plugins-linux-amd64-v1.1.1.tgz -C /opt/cni/bin/

ls /opt/cni/bin

#wget https://github.com/containerd/containerd/releases/download/v1.6.4/cri-containerd-cni-1.6.4-linux-amd64.tar.gz

#解压
tar -xzf cri-containerd-cni-*-linux-amd64.tar.gz -C /

rm -rf /etc/cni/net.d/10-containerd-net.conflist

#创建服务启动文件
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
```

### 2.1.1配置Containerd所需的模块

```shell
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF
```

### 2.1.2加载模块

```shell
systemctl restart systemd-modules-load.service
```

### 2.1.3配置Containerd所需的内核

```shell
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# 加载内核

sysctl --system
```

### 2.1.4创建Containerd的配置文件

```shell
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml


修改Containerd的配置文件
sed -i "s#SystemdCgroup\ \=\ false#SystemdCgroup\ \=\ true#g" /etc/containerd/config.toml

cat /etc/containerd/config.toml | grep SystemdCgroup

sed -i "s#k8s.gcr.io#registry.cn-hangzhou.aliyuncs.com/chenby#g" /etc/containerd/config.toml

cat /etc/containerd/config.toml | grep sandbox_image

# 找到containerd.runtimes.runc.options，在其下加入SystemdCgroup = true

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
SystemdCgroup = true
[plugins."io.containerd.grpc.v1.cri".cni]


# 将sandbox_image默认地址改为符合版本地址

sandbox_image = "registry.cn-hangzhou.aliyuncs.com/chenby/pause:3.6"
```

### 2.1.5启动并设置为开机启动

```shell
systemctl daemon-reload
systemctl enable --now containerd
```
### 2.1.6配置crictl客户端连接的运行时位置

```shell
#wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.24.2/crictl-v1.24.2-linux-amd64.tar.gz

#解压
tar xf crictl-v1.24.2-linux-amd64.tar.gz -C /usr/bin/
#生成配置文件

cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF

#测试
systemctl restart  containerd
crictl info

```
