### file模块 创建文件夹
ansible -i inventory all -m file -a "path=/tmp/ansible state=directory"
### file模块 创建文件
ansible -i inventory all -m file -a "path=/tmp/ansible/test.txt state=touch"
### file模块 删除文件夹
ansible -i inventory all -m file -a "path=/tmp/ansible state=absent"
### file模块 删除文件
ansible -i inventory all -m file -a "path=/tmp/ansible/test.txt state=absent"
### file模块 修改文件权限
ansible -i inventory all -m file -a "path=/tmp/ansible/test.txt mode=777"
### file模块 修改文件所有者
ansible -i inventory all -m file -a "path=/tmp/ansible/test.txt owner=root"
### file模块 修改文件所属组
ansible -i inventory all -m file -a "path=/tmp/ansible/test.txt group=root"
### file模块 创建软链接
ansible -i inventory all -m file -a "path=/tmp/ansible/test.txt state=link src=/tmp/ansible/test.txt"
### file模块 创建硬链接
ansible -i inventory all -m file -a "path=/tmp/ansible/test.txt state=hard src=/tmp/ansible/test.txt"
### file模块 修改文件时间
ansible -i inventory all -m file -a "path=/tmp/ansible/test.txt atime=2019-01-01 mtime=2019-01-01"

### copy模块 backup备份后copy
ansible -i inventory all -m copy -a "src=/etc/hosts backup=yes dest=/tmp/hosts  " 
### copy模块 copy文件夹
ansible -i inventory all -m copy -a "src=/etc/hosts dest=/tmp/hosts  "
### systemd模块 reload nginx服务
ansible -i inventory all -m systemd -a "name=nginx state=reloaded"

### systemd模块 启动cron服务
ansible -i inventory all -m systemd -a "name=cron state=started enabled=yes"

### yum_repository模块 添加yum源
ansible -i inventory all -m yum_repository -a "name=epel description='Extra Packages for Enterprise Linux 7 - $basearch' baseurl=http://mirrors.aliyun.com/epel/7/$basearch/ gpgcheck=0 enabled=1"
### yum 模块 安装nginx
ansible -i inventory all -m yum -a "name=nginx state=present"
### yum 模块 卸载nginx
ansible -i inventory all -m yum -a "name=nginx state=absent"

### wget 模块 下载文件
ansible -i inventory all -m wget -a "url=http://mirrors.aliyun.com/epel/7/x86_64/Packages/e/epel-release-7-11.noarch.rpm dest=/tmp/epel-release-7-11.noarch.rpm"

