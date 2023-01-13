## 关于k8s的日常总结及分享

### Kubernetes 镜像使用帮助

Kubernetes 是用于自动部署，扩展和管理容器化应用程序的开源系统。详情可见 [官方介绍](https://kubernetes.io/zh/)。

**硬件架构: `x86_64`, `armhfp`, `aarch64`**

#### Debian/Ubuntu 用户

首先导入 gpg key：

```
sudo curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg
```

新建 `/etc/apt/sources.list.d/kubernetes.list`，内容为

```
deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://mirrors.tuna.tsinghua.edu.cn/kubernetes/apt kubernetes-xenial main
```

#### RHEL/CentOS 用户

新建 `/etc/yum.repos.d/kubernetes.repo`，内容为：

```
[kubernetes]
name=kubernetes
baseurl=https://mirrors.tuna.tsinghua.edu.cn/kubernetes/yum/repos/kubernetes-el7-$basearch
enabled=1
```

#### Minikube

请到 [minikube 镜像](https://mirrors.tuna.tsinghua.edu.cn/github-release/kubernetes/minikube/LatestRelease/) 下载。

### Linux 系统中的 Bash 自动补全功能

#### 简介

kubectl 的 Bash 补全脚本可以用命令 `kubectl completion bash` 生成。 在 Shell 中导入（Sourcing）补全脚本，将启用 kubectl 自动补全功能。

然而，补全脚本依赖于工具 [**bash-completion**](https://github.com/scop/bash-completion)， 所以要先安装它（可以用命令 `type _init_completion` 检查 bash-completion 是否已安装）。

#### 安装 bash-completion

很多包管理工具均支持 bash-completion（参见[这里](https://github.com/scop/bash-completion#installation)）。 

ubuntu

```
apt-get install bash-completion
```

centos

```
yum install bash-completion
```

上述命令将创建文件 `/usr/share/bash-completion/bash_completion`，它是 bash-completion 的主脚本。 依据包管理工具的实际情况，你需要在 `~/.bashrc` 文件中手工导入此文件。

要查看结果，请重新加载你的 Shell，并运行命令 `type _init_completion`。 如果命令执行成功，则设置完成，否则将下面内容添加到文件 `~/.bashrc` 中：

```bash
source /usr/share/bash-completion/bash_completion
```

重新加载 Shell，再输入命令 `type _init_completion` 来验证 bash-completion 的安装状态

```
type _init_completion
```

#### 启动 kubectl 自动补全功能[ ](https://kubernetes.io/zh-cn/docs/tasks/tools/included/optional-kubectl-configs-bash-linux/#enable-kubectl-autocompletion)

**Bash**

你现在需要确保一点：kubectl 补全脚本已经导入（sourced）到 Shell 会话中。 可以通过以下两种方法进行设置：

- [当前用户](https://kubernetes.io/zh-cn/docs/tasks/tools/included/optional-kubectl-configs-bash-linux/#kubectl-bash-autocompletion-0)
- [系统全局](https://kubernetes.io/zh-cn/docs/tasks/tools/included/optional-kubectl-configs-bash-linux/#kubectl-bash-autocompletion-1)

**系统全局**

```bash
kubectl completion bash | sudo tee /etc/bash_completion.d/kubectl > /dev/null
```

如果 kubectl 有关联的别名，你可以扩展 Shell 补全来适配此别名：

```bash
echo 'alias k=kubectl' >>~/.bashrc
echo 'complete -o default -F __start_kubectl k' >>~/.bashrc
```

**env和set的区别是，set命令可以查看所有变量，而env命令只能查看环境变量**
### k8s集群开启ipvs模式
1.2kube-proxy开启ipvs的前置条件
 由于ipvs已经加入到了内核的主干，所以为kube-proxy开启ipvs的前提需要加载以下的内核模块：
 ip_vs
 ip_vs_rr
 ip_vs_wrr
 ip_vs_sh
 nf_conntrack_ipv4

在所有的Kubernetes节点node1和node2上执行以下脚本:
```
 cat > /etc/sysconfig/modules/ipvs.modules <<EOF
 #!/bin/bash
 modprobe  ip_vs
 modprobe  ip_vs_rr
 modprobe  ip_vs_wrr
 modprobe  ip_vs_sh
 modprobe  nf_conntrack_ipv4
 EOF
```
 ```
 chmod 755 /etc/sysconfig/modules/ipvs.modules && bash /etc/sysconfig/modules/ipvs.modules && lsmod | grep -e ip_vs -e nf_conntrack_ipv4
 ```
 脚本创建了的/etc/sysconfig/modules/ipvs.modules文件，保证在节点重启后能自动加载所需模块。 使用lsmod | grep -e ip_vs -e nf_conntrack_ipv4命令查看是否已经正确加载所需的内核模块。
 在所有节点上安装ipset软件包
 ```
 yum install ipset -y
 ```
 为了方便查看ipvs规则我们要安装ipvsadm(可选)
 ```
 yum install ipvsadm -y
 ```
#修改ConfigMap的kube-system/kube-proxy中的config.conf，把 mode: “” 改为mode: “ipvs” 保存退出即可

### k8s内核参数优化
```
# conntrack优化
net.netfilter.nf_conntrack_tcp_be_liberal = 1 # 容器环境下，开启这个参数可以避免 NAT 过的 TCP 连接 带宽上不去。
net.netfilter.nf_conntrack_tcp_loose = 1 
net.netfilter.nf_conntrack_max = 3200000
net.netfilter.nf_conntrack_buckets = 1600512
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30

# 以下三个参数是 arp 缓存的 gc 阀值，相比默认值提高了，避免在某些场景下arp缓存溢出导致网络超时，参考：https://k8s.imroc.io/troubleshooting/cases/arp-cache-overflow-causes-healthcheck-failed
net.ipv4.neigh.default.gc_thresh1="2048"
net.ipv4.neigh.default.gc_thresh2="4096"
net.ipv4.neigh.default.gc_thresh3="8192"

net.ipv4.tcp_max_orphans="32768"
vm.max_map_count="262144"
kernel.threads-max="30058"
net.ipv4.ip_forward=1

# 磁盘 IO 优化: https://www.cnblogs.com/276815076/p/5687814.html
vm.dirty_background_bytes = 0
vm.dirty_background_ratio = 5
vm.dirty_bytes = 0
vm.dirty_expire_centisecs = 50
vm.dirty_ratio = 10
vm.dirty_writeback_centisecs = 50
vm.dirtytime_expire_seconds = 43200

```

### Pod 调参汇总
```
# socket buffer优化
net.ipv4.tcp_wmem = 4096        16384   4194304
net.ipv4.tcp_rmem = 4096        87380   6291456
net.ipv4.tcp_mem = 381462       508616  762924
net.core.rmem_default = 8388608
net.core.rmem_max = 26214400 # 读写 buffer 调到 25M 避免大流量时导致 buffer 满而丢包 "netstat -s" 可以看到 receive buffer errors 或 send buffer errors
net.core.wmem_max = 26214400
 
# timewait相关优化
net.ipv4.tcp_max_tw_buckets = 131072 # 这个优化意义不大
net.ipv4.tcp_timestamps = 1  # 通常默认本身是开启的
#net.ipv4.tcp_tw_reuse = 1 # 仅对客户端有效果，对于高并发客户端，可以复用TIME_WAIT连接端口，避免源端口耗尽建连失败
net.ipv4.ip_local_port_range="1024 65535" # 对于高并发客户端，加大源端口范围，避免源端口耗尽建连失败（确保容器内不会监听源端口范围的端口)
net.ipv4.tcp_fin_timeout=30 # 缩短TIME_WAIT时间,加速端口回收
 
# 握手队列相关优化
net.ipv4.tcp_max_syn_backlog = 10240 # 没有启用syncookies的情况下，syn queue(半连接队列)大小除了受somaxconn限制外，也受这个参数的限制，默认1024，优化到8096，避免在高并发场景下丢包
net.core.somaxconn = 65535 # 表示socket监听(listen)的backlog上限，也就是就是socket的监听队列(accept queue)，当一个tcp连接尚未被处理或建立时(半连接状态)，会保存在这个监听队列，默认为 128，在高并发场景下偏小，优化到 32768。参考 https://imroc.io/posts/kubernetes-overflow-and-drop/
net.ipv4.tcp_syncookies = 1

# fd优化
fs.file-max=1048576 # 提升文件句柄上限，像 nginx 这种代理，每个连接实际分别会对 downstream 和 upstream 占用一个句柄，连接量大的情况下句柄消耗就大。
fs.inotify.max_user_instances="8192" # 表示同一用户同时最大可以拥有的 inotify 实例 (每个实例可以有很多 watch)
fs.inotify.max_user_watches="524288" # 表示同一用户同时可以添加的watch数目（watch一般是针对目录，决定了同时同一用户可以监控的目录数量) 默认值 8192 在容器场景下偏小，在某些情况下可能会导致 inotify watch 数量耗尽，使得创建 Pod 不成功或者 kubelet 无法启动成功，将其优化到 524288

### 华为云cce
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.bridge.bridge-nf-call-arptables=1
net.ipv4.ip_local_reserved_ports = 30000-32767
net.ipv4.ip_forward=1

vm.swappiness=0
net.ipv4.tcp_max_tw_buckets=5000
fs.nr_open=1200000 
fs.file-max=200000
### ipvs bug会影响性能
net.ipv4.vs.conntrack=1
net.ipv4.vs.conn_reuse_mode=1
net.ipv4.vs.expire_nodest_conn=1
```

### kubesnetes证书过期查看及更新

**查看证书情况**

```
kubeadm certs check-expiration #高版本
```



```
kubeadm  alpha certs check-expiration #低版本
```

**备份原来的证书**

```
cp -r /etc/kubernetes /etc/kubernetes.old
```



**在每个 Master 节点上执行命令更新证书**

```
kubeadm certs renew all #高版本
```



```
kubeadm alpha certs renew all #低版本
```



**Master 节点上重启相关服务**

```
docker ps |egrep "k8s_kube-apiserver|k8s_kube-scheduler|k8s_kube-controller"|awk '{print $1}'|xargs docker restart
```



**更新 ~/.kube/config 文件**

```
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

