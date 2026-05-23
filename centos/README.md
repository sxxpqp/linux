# CentOS 系统管理

CentOS 7 系统运维脚本与笔记。

## 文件说明

| 文件 | 说明 |
|---|---|
| [centos-ops-notes.md](centos-ops-notes.md) | CentOS 运维笔记：yum 镜像源更换（CentOS 7/8 清华源）、firewalld 服务管理命令（start/stop/enable）、firewall-cmd 规则配置；iptables 安装、清空规则、白名单配置、端口开放、IP 屏蔽、端口映射；代理上网设置 |
| [centos-security-init.sh](centos-security-init.sh) | 安全初始化脚本：密码策略（login.defs 过期时间、pam 密码复杂度）、SSH 配置（端口/root登录/密钥）、创建普通用户并配置 sudo、history 记录优化、登录失败锁定（pam_tally2）、常见漏洞修复 |
| [lvm-operation.md](lvm-operation.md) | LVM 操作指南：pvcreate/vgcreate/lvcreate 创建逻辑卷、ext4 文件系统扩容（lvextend + resize2fs）、xfs 文件系统扩容（lvextend + xfs_growfs） |
| [ssh-hostsdeny-block.sh](ssh-hostsdeny-block.sh) | SSH 暴力破解防护：通过 lastb 检测失败登录 IP，自动写入 /etc/hosts.deny 封禁 |
| [upgradekernel.sh](upgradekernel.sh) | CentOS 7 内核升级脚本：ELRepo 源配置、安装最新主线稳定内核、grub2 设置默认启动项、重启验证 |
