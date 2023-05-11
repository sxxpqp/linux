## 关于docker的日常总结及分享
### 自动安装
**Docker** 提供了一个自动配置与安装的脚本，支持 Debian、RHEL、SUSE 系列及衍生系统的安装。

以下内容假定

您为 root 用户，或有 sudo 权限，或知道 root 密码；
您系统上有 curl 或 wget

```
export DOWNLOAD_URL="https://mirrors.tuna.tsinghua.edu.cn/docker-ce"
```


#### 如您使用 curl
```
curl -fsSL https://get.docker.com/ | sh
```


#### 如您使用 wget
```
wget -O- https://get.docker.com/ | sh
```

#### Debian/Ubuntu 用户

以下内容根据 官方文档 修改而来。

如果你过去安装过 docker，先删掉:

```
sudo apt-get remove docker docker-engine docker.io containerd runc
```
首先安装依赖:

```
sudo apt-get install apt-transport-https ca-certificates curl gnupg2 software-properties-common
```
**根据你的发行版，下面的内容有所不同。你使用的发行版：** 

#### Debian
信任 Docker 的 GPG 公钥:

```
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
```
添加软件仓库:

```
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/debian \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```
最后安装

```
sudo apt-get update
sudo apt-get install docker-ce
```
#### ubuntu

信任 Docker 的 GPG 公钥:



```
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
```

添加软件仓库:



```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

最后安装

```
sudo apt-get update
sudo apt-get install docker-ce
```

#### Fedora/CentOS/RHEL
以下内容根据 官方文档 修改而来。

如果你之前安装过 docker，请先删掉

```
sudo yum remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine
```
安装一些依赖

```
sudo yum install -y yum-utils device-mapper-persistent-data lvm2
```
根据你的发行版下载repo文件: 
#### CentOS/RHEL
```
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
```
把软件仓库地址替换为 TUNA:

```
sudo sed -i 's+download.docker.com+mirrors.tuna.tsinghua.edu.cn/docker-ce+' /etc/yum.repos.d/docker-ce.repo
```
最后安装:

```
sudo yum makecache fast
sudo yum install docker-ce
```



### 配置docker镜像加速器

针对Docker客户端版本大于 1.10.0 的用户

您可以通过修改daemon配置文件/etc/docker/daemon.json来使用加速器

```
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json <<-'EOF'
{
"registry-mirrors": ["https://egkr0rl5.mirror.aliyuncs.com"],
"insecure-registries":["harbor.iot.store:8085"],
"log-driver":"json-file",
"log-opts": {"max-size":"500m", "max-file":"3"}
}
EOF
sudo systemctl daemon-reload
sudo systemctl reload docker
sudo docker info
```



### **解决 Docker 日志文件太大的问题**

编辑文件/etc/docker/daemon.json, 增加以下日志的配置

```
"log-driver":"json-file",
"log-opts": {"max-size":"500m", "max-file":"3"}
```

max-size=500m，意味着一个容器日志大小上限是500M，
max-file=3，意味着一个容器有三个日志，分别是id+.json、id+1.json、id+2.json。

查看docker日志的大小容器的排序

```
docker system ps
```

```
sudo du -d1 -h /var/lib/docker/containers | sort -h
```

清理容器的日志

```
echo >xxx.log
```

### 删除容器镜像

```
docker image prune
```

### docker文件目录/var/lib/docker过大 

**迁移数据到/data/**

```
systemctl stop docker
systemctl stop docker.socket
```

```
mv /var/lib/docker /data/
```

```
ln -s /data/docker /var/lib/docker
```

```
systemctl start docker
```
### 批量打包镜像
```
docker save $(docker images | grep -v "REPOSITORY" | awk 'BEGIN{OFS=":";ORS=" "}{print $1,$2}') -o haha.tar
```
### 批量拉取镜像推到自己的阿里云仓库上
sxxpqp:仓库名称 修改成自己的仓库名称，需要先登陆
```
docker login --username=1019466494@qq.com registry.cn-hangzhou.aliyuncs.com
```
#第一列和第二列是镜像名称和版本号，可以根据自己的需求修改
```
docker images|grep -v REPOSITORY|grep ^gji|awk '{print $1":"$2}' > images.txt
```
```
#!/bin/bash
for image in $(cat images.txt)
do
docker pull $image
strA=`echo $image|awk 'BEGIN{FS="/";OFS="/"}{print $1,$2}'`
result=$(echo $image | grep "${strA}")
if [[ "$result" != "" ]];then
docker tag ${image} registry.cn-hangzhou.aliyuncs.com/sxxpqp${image#$strA}
docker push registry.cn-hangzhou.aliyuncs.com/sxxpqp${image#$strA}
fi
done
```

### ssh实现免密登陆

访问主机生产公钥 ~/.ssh/id_rsa.pub

```
ssh-keygen
```

复制公钥到被控主机上

```
ssh-copy-id user@server
ssh-copy-id -i ~/.ssh/id_rsa.pub user@server

chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

### 查看linux的cpu和内存排序

内存排序

```
 ps aux |grep -v USER | sort -nk +4 | tail 
```

cpu排序

```
 ps aux |grep -v USER | sort -nk +3 | tail 
```

### netstat和awk命令来统计网络连接数

```
yum install net-tools -y
```

```
netstat -n | awk '/^tcp/ {++state[$NF]} END {for(key in state) print key,state[key]}'
```

**查看同时连接服务器 IP **

```
netstat -an|awk '{print $4}'|sort|uniq -c|sort -nr|head
```

```
netstat -an|awk -F: '{print $2}'|sort|uniq -c|sort -nr|head
```

### 安全加固

**系统中是否存在空密码账户**

```
awk -F: '($2==""){print $1}' /etc/shadow
```

**查找uid值为0的用户**

```
awk -F: '($3==0||$4==0){print $1}' /etc/passwd
```

**查找gid值为0的用户**

```
awk -F: '($3==0||$4==0){print $1}' /etc/passwd
```



**禁止Control-Alt-Delete 键盘重启系统命令**

```
ls /usr/lib/systemd/system/ctrl-alt-del.target
```



#### **备份配置文件**

```
cp -a  /usr/lib/systemd/system/ctrl-alt-del.target         /usr/lib/systemd/system/ctrl-alt-del.target.default
```

```
rm -rf  /usr/lib/systemd/system/ctrl-alt-del.target
```

### **隐藏系统版本信息**

```
#mv /etc/issue /etc/issue.bak
#mv /etc/issue.net /etc/issue.net.bak
```

