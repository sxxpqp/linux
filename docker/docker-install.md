国内linux一键安装命令 支持centos ubuntu系统等
```
export DOWNLOAD_URL="https://mirrors.tuna.tsinghua.edu.cn/docker-ce"
```
```
curl -fsSl https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/main/linux/docker/install.sh|sh -s docker --mirror Aliyun
```
有报错请添加--version 20.10
```
curl -fsSl https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/main/linux/docker/install.sh|sh -s docker  --mirror Aliyun --version 20.10
```
配置加速源 点击链接
```
 https://www.sxxpqp.top/archives/docker-pei-zhi-jing-xiang-jia-su
```
将当前用户添加到 docker 组 
```
sudo usermod -aG docker $USER 
```
# 注销并重新登录，或者使用 
```
newgrp docker 
```
# 然后运行 Docker 命令 
```
docker ps -a
```