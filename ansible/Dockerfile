# Dockerfile构建systemd+sshd
# 基础镜像
FROM ubuntu:18.04

# build参数
ARG user=turing

# 元数据
LABEL maintainer="sxxpqp" email="sxxpqp@gmail.com"


#更换清华源
RUN sed -i 's/archive.ubuntu.com/mirrors.tuna.tsinghua.edu.cn/g' /etc/apt/sources.list
# 安装systemd + sshd
RUN apt-get update && apt-get install -y systemd openssh-server sudo

# 添加用户：赋予sudo权限，指定密码
RUN useradd --create-home --no-log-init --shell /bin/bash ${user} \
    && adduser ${user} sudo \
    && echo "${user}:Turing@2022" | chpasswd

# 改变用户的UID和GID
# RUN usermod -u 1000 ${user} && usermod -G 1000 ${user}

# 指定容器起来的工作目录
WORKDIR /home/${user}

# 指定容器起来的登录用户
USER ${user}



# docker build -t  ubuntu1804:test .
# 启动容器
# docker run -d  --privileged --name ubuntu1804 -p 2222:22  -u root ubuntu1804:test /sbin/init
# docker exec -it ubuntu1804 /bin/bash
# 删除容器
# docker rm -f ubuntu1804
