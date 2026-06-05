# CentOS 7 升级内核到 5.4 LTS(elrepo kernel-lt)

> 源: https://github.com/sxxpqp/linux/blob/main/centos/7/updatekernel.md
> 状态: 验证过

CentOS 7 默认内核 3.10 太老,跑 eBPF / 新版 Docker / 现代 K8s 都不够。升到 5.4 LTS(elrepo `kernel-lt`)。

## 1. 下载 kernel-lt RPM

```bash
wget https://mirrors.coreix.net/elrepo-archive-archive/kernel/el7/x86_64/RPMS/kernel-lt-5.4.203-1.el7.elrepo.x86_64.rpm
wget https://mirrors.coreix.net/elrepo-archive-archive/kernel/el7/x86_64/RPMS/kernel-lt-devel-5.4.203-1.el7.elrepo.x86_64.rpm
wget https://mirrors.coreix.net/elrepo-archive-archive/kernel/el7/x86_64/RPMS/kernel-lt-headers-5.4.203-1.el7.elrepo.x86_64.rpm
```

## 2. 安装

```bash
rpm -ivh kernel-lt-5.4.203-1.el7.elrepo.x86_64.rpm
rpm -ivh kernel-lt-devel-5.4.203-1.el7.elrepo.x86_64.rpm

# 或者一键装当前目录所有 RPM
rpm -Uvh *.rpm   # 冲突时:yum remove kernel-headers
```

## 3. 确认已装版本

```bash
rpm -qa | grep kernel
```

期望看到 `kernel-lt-5.4.203` 系列(以及残留的老 `kernel-3.10.0-*`):

```
kernel-lt-devel-5.4.203-1.el7.elrepo.x86_64
kernel-lt-5.4.203-1.el7.elrepo.x86_64
kernel-devel-3.10.0-1160.53.1.el7.x86_64
kernel-3.10.0-1160.53.1.el7.x86_64
kernel-3.10.0-1127.el7.x86_64
kernel-devel-3.10.0-1127.el7.x86_64
kernel-headers-3.10.0-1160.53.1.el7.x86_64
kernel-tools-libs-3.10.0-1160.53.1.el7.x86_64
kernel-tools-3.10.0-1160.53.1.el7.x86_64
```

## 4. 设置默认启动新内核

### 4.1 查看启动顺序

```bash
awk -F\' '$1=="menuentry " {print $2}' /etc/grub2.cfg
```

期望(0 号位是新内核):

```
CentOS Linux (5.4.203-1.el7.elrepo.x86_64) 7 (Core)        ← 0
CentOS Linux (3.10.0-1160.53.1.el7.x86_64) 7 (Core)        ← 1
CentOS Linux (3.10.0-1127.el7.x86_64) 7 (Core)             ← 2
CentOS Linux (0-rescue-c9b49c6c11334518a7adc404ff6315b6) 7 (Core)
```

### 4.2 设置默认启动 0 号位

```bash
grub2-set-default 0
```

### 4.3 重启生效

```bash
reboot
```

重启后 `uname -r` 应该是 `5.4.203-1.el7.elrepo.x86_64`。

## 5. 配套补装(可选)

需要编译内核模块 / 第三方驱动时:

```bash
sudo yum install epel-release
sudo yum groupinstall "Development Tools"
```
