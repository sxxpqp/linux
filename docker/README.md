## 关于docker的日常总结及分享

### docker 拉取国外镜像慢的问题解决 通过clash代理

```
vi /etc/systemd/system/docker.service 
```
添加env
```
[Service]
Environment="HTTP_PROXY=http://192.168.2.173:1080/" "HTTPS_PROXY=http://192.168.2.173:1080/"
```
```
systemctl daemon-reload
systemctl restart docker
```

### 二进制安装docker
#### 下载二进制文件
```
wget https://download.docker.com/linux/static/stable/x86_64/docker-20.10.9.tgz
```
#### 解压
```
tar -xzvf docker-20.10.9.tgz
```
```
cp docker/* /usr/bin/
```
```
cat<<EOF >> /usr/lib/systemd/system/docker.service
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/dockerd
ExecReload=/bin/kill -s HUP $MAINPID
LimitNOFILE=infinity
LimitNPROC=infinity
TimeoutStartSec=0
Delegate=yes
KillMode=process
Restart=on-failure
StartLimitBurst=3
StartLimitInterval=60s

[Install]
WantedBy=multi-user.target
EOF
```
#### 开机自启和启动docker
```
systemctl daemon-reload
systemctl start docker
systemctl enable docker
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

# 读取 images.txt 中的每个镜像名称
for image in $(cat images.txt); do
    # 获取镜像名的前两部分（例如 registry/repo）
    strA=$(echo $image | awk 'BEGIN{FS="/";OFS="/"}{print $1,$2}')

    # 检查是否包含仓库部分
    if [[ "$image" == "$strA"* ]]; then
        # 输出镜像和目标仓库名称
        echo "镜像：${image}"
        
        # 为镜像添加仓库标签并推送到新的仓库
        new_image="dockerhub.kubekey.local/kubesphereio$(echo $image | sed "s#^$strA##")"
        echo "推送到：${new_image}"

        # 标记镜像并推送
        docker tag "$image" "$new_image"
        docker push "$new_image"
    else
        echo "跳过无效镜像：$image"
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

