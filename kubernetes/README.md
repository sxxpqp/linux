## 关于k8s的日常总结及分享

### 快速安装高可用 Kubernetes 集群

#### 安装sealos

```
wget  https://github.com/labring/sealos/releases/download/v4.1.3/sealos_4.1.3_linux_amd64.tar.gz  && \
>     tar -zxvf sealos_4.1.3_linux_amd64.tar.gz sealos &&  chmod +x sealos && mv sealos /usr/bin 
```

#### 使用 cri-docker 镜像

```
sealos run labring/kubernetes-docker:v1.20.5-4.1.3 labring/helm:v3.8.2      --masters 192.168.1.171,192.168.1.172,192.168.1.173      --nodes 192.168.1.174 -p 1
```

```
sealos reset #安装错误，恢复后重新安装
```

```
sealos run labring/calico:v3.22.1-amd64
```

```
sealos run labring/openebs:v1.9.0 # 安装openebs
```

```
sealos run labring/minio-operator:v4.4.16 labring/ingress-nginx:4.1.0 
```

```
sealos run labring/mysql-operator:8.0.23-14.1 
```

```
sealos run labring/redis-operator:3.1.4 # 喜欢的话可以把它们写一起
```



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
#### 提高网络性能
```bash
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_fin_timeout = 30
#net.ipv4.tcp_tw_reuse = 1
#net.ipv4.tcp_tw_recycle = 1
net.bridge.bridge-nf-call-iptables = 1
```
#### 提高文件打开数及提高文件系统性能
```bash
fs.inotify.max_user_watches = 1048576
fs.file-max = 1280000
vm.max_map_count = 262144
fs.nr_open = 1280000
```
#### 提高内存管理性能
```bash
vm.swappiness = 0
vm.overcommit_memory = 1
vm.panic_on_oom = 0
```
#### 提高CPU性能
```bash
kernel.sched_min_granularity_ns = 10000000
kernel.sched_wakeup_granularity_ns = 15000000
kernel.sched_migration_cost_ns = 5000000
```
#### conntrack
```bash
net.netfilter.nf_conntrack_max = 1000000
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 120
```



### 华为云cce
```
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.bridge.bridge-nf-call-arptables=1
net.ipv4.ip_local_reserved_ports = 30000-32767
net.ipv4.ip_forward=1

vm.swappiness=0
net.ipv4.tcp_max_tw_buckets=5000
fs.nr_open=1280000 
fs.file-max=1280000
### ipvs bug会影响性能
net.ipv4.vs.conntrack=1
net.ipv4.vs.conn_reuse_mode=1
net.ipv4.vs.expire_nodest_conn=1
```

### 设置ulimit
```bash
cat >> /etc/security/limits.conf <<EOF
* soft nofile 1280000
* hard nofile 1280000
* soft nproc 1280000
* hard nproc 1280000
EOF
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
##修改master的角色
```
kubectl label  nodes k8s-master01 node-role.kubernetes.io/master=
```
label 可以在工作负载和server、pod、pvc、pv中使用到，如nodeselector affinity使用到
##service 模式
clusterIP #含headless服务clusterip:None,可以设置为clusterip有ip地址,但没有使用selector，就不会自动创建endpoint，可以自己设置创建ep，实现反代的效果。
nodePort #宿主机上暴露端口
loadBlancer #使用云上的负载均衡，或者本地使用openelb
externalName #通过代理到域名上，会出现跨域问题，需要处理。
hostPort #pod的port使用宿主机的端口
hostNetwork #pod使用宿主机的ip触发了systemd的bug，执行systemctl daemon-reexec 重新加载一下。


pod无法正常启动 、删除等操作，可能是因为kubelet的systemd配置文件有问题，导致kubelet无法正常启动，可以通过以下命令查看kubelet的状态：
```
systemctl status kubelet
```
触发了systemd的bug,可以通过以下命令解决：
```
执行systemctl daemon-reexec 重新加载一下。
```