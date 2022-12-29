## 关于docker的日常总结及分享
## 自动安装
**Docker 提供了一个自动配置与安装的脚本，支持 Debian、RHEL、SUSE 系列及衍生系统的安装。**

以下内容假定

您为 root 用户，或有 sudo 权限，或知道 root 密码；
您系统上有 curl 或 wget

```
export DOWNLOAD_URL="https://mirrors.tuna.tsinghua.edu.cn/docker-ce"
```


# 如您使用 curl
```
curl -fsSL https://get.docker.com/ | sh
```


# 如您使用 wget
```
wget -O- https://get.docker.com/ | sh
```

### Debian/Ubuntu 用户
以下内容根据 官方文档 修改而来。

如果你过去安装过 docker，先删掉:

```
sudo apt-get remove docker docker-engine docker.io containerd runc
```
首先安装依赖:

```
sudo apt-get install apt-transport-https ca-certificates curl gnupg2 software-properties-common
```
### 根据你的发行版，下面的内容有所不同。你使用的发行版： 
### Debian
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
### ubuntu

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

### Fedora/CentOS/RHEL
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
### CentOS/RHEL
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