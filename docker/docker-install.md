# Docker 一键安装(国内加速版)

> 源: https://github.com/sxxpqp/linux/blob/main/docker/docker-install.md
> 状态: 验证过

国内 Linux 一键安装 Docker,支持 CentOS / Ubuntu / Debian。安装脚本来自本仓库,走 Nexus 代理。

## 1. 安装(默认最新版)

```bash
export DOWNLOAD_URL="https://mirrors.tuna.tsinghua.edu.cn/docker-ce"

curl -fsSl https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/install.sh \
  | sh -s docker --mirror Aliyun
```

## 1b. 安装指定版本(报错时用)

```bash
curl -fsSl https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/install.sh \
  | sh -s docker --mirror Aliyun --version 20.10
```

## 2. 配置镜像加速

详细配置见:<https://www.sxxpqp.top/archives/docker-pei-zhi-jing-xiang-jia-su>

## 3. 把当前用户加进 docker 组(免 sudo)

```bash
sudo usermod -aG docker $USER
```

注销并重新登录,或者立即生效:

```bash
newgrp docker
```

## 4. 验证

```bash
docker ps -a
```
