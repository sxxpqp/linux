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
## k8s集群开启ipvs模式
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