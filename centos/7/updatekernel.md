wget https://mirrors.coreix.net/elrepo-archive-archive/kernel/el7/x86_64/RPMS/kernel-lt-devel-5.4.203-1.el7.elrepo.x86_64.rpm
wget https://mirrors.coreix.net/elrepo-archive-archive/kernel/el7/x86_64/RPMS/kernel-lt-headers-5.4.203-1.el7.elrepo.x86_64.rpm
wget https://mirrors.coreix.net/elrepo-archive-archive/kernel/el7/x86_64/RPMS/kernel-lt-5.4.203-1.el7.elrepo.x86_64.rpm


rpm -ivh kernel-lt-5.4.203-1.el7.elrepo.x86_64.rpm
rpm -ivh kernel-lt-devel-5.4.203-1.el7.elrepo.x86_64.rpm
或者
#一键安装所有
rpm -Uvh *.rpm  #yum remove kernel-headers





[root@ecs-2b3c ~]# rpm -qa | grep kernel
kernel-lt-devel-5.4.203-1.el7.elrepo.x86_64
kernel-devel-3.10.0-1160.53.1.el7.x86_64
kernel-lt-5.4.203-1.el7.elrepo.x86_64
kernel-3.10.0-1127.el7.x86_64
kernel-devel-3.10.0-1127.el7.x86_64
kernel-headers-3.10.0-1160.53.1.el7.x86_64
kernel-3.10.0-1160.53.1.el7.x86_64
kernel-tools-libs-3.10.0-1160.53.1.el7.x86_64
kernel-tools-3.10.0-1160.53.1.el7.x86_64


# 查看启动顺序
[root@ecs-2b3c ~]# awk -F\' '$1=="menuentry " {print $2}' /etc/grub2.cfg
CentOS Linux (5.4.203-1.el7.elrepo.x86_64) 7 (Core)
CentOS Linux (3.10.0-1160.53.1.el7.x86_64) 7 (Core)
CentOS Linux (3.10.0-1127.el7.x86_64) 7 (Core)
CentOS Linux (0-rescue-c9b49c6c11334518a7adc404ff6315b6) 7 (Core)

# 设置启动顺序
[root@ecs-2b3c ~]# grub2-set-default 0

# 重启生效
[root@ecs-2b3c ~]# reboot


sudo yum install epel-release

sudo yum groupinstall "Development Tools"

