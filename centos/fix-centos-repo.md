# CentOS 7 更换清华源

## 方式一：直接替换 repo 文件

上传 [CentOS-Base.repo](#) 到目标机器并执行：

```bash
cp CentOS-Base.repo /etc/yum.repos.d/CentOS-Base.repo
yum makecache
```

<details>
<summary>CentOS-Base.repo 内容</summary>

```ini
[base]
name=CentOS-$releasever - Base
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=os&infra=$infra
baseurl=https://mirrors4.tuna.tsinghua.edu.cn/centos-vault/7.9.2009/os/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

#released updates
[updates]
name=CentOS-$releasever - Updates
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=updates&infra=$infra
baseurl=https://mirrors4.tuna.tsinghua.edu.cn/centos-vault/7.9.2009/updates/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

#additional packages that may be useful
[extras]
name=CentOS-$releasever - Extras
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=extras&infra=$infra
baseurl=https://mirrors4.tuna.tsinghua.edu.cn/centos-vault/7.9.2009/extras/$basearch/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7

#additional packages that extend functionality of existing packages
[centosplus]
name=CentOS-$releasever - Plus
#mirrorlist=http://mirrorlist.centos.org/?release=$releasever&arch=$basearch&repo=centosplus&infra=$infra
baseurl=https://mirrors4.tuna.tsinghua.edu.cn/centos-vault/7.9.2009/centosplus/$basearch/
gpgcheck=1
enabled=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
```

</details>

## 方式二：sed 替换（在目标机器上直接执行）

```bash
sed -i \
  -e 's|^mirrorlist=|#mirrorlist=|' \
  -e 's|^#baseurl=http://mirror.centos.org/centos/\$releasever/\(.*\)|baseurl=https://mirrors4.tuna.tsinghua.edu.cn/centos-vault/7.9.2009/\1|' \
  /etc/yum.repos.d/CentOS-Base.repo
```

执行后 `yum makecache` 验证。
```
yum makecache
```