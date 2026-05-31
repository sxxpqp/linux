#!/bin/bash

# 构建镜像
docker build -D --rm --no-cache -t centos:systemd -f Dockerfile .

# 运行容器并映射端口
docker run --privileged --name sshd -v /sys/fs/cgroup:/sys/fs/cgroup:ro -p 2322:22 -d registry.cn-hangzhou.aliyuncs.com/sxxpqp/centos:systemd-ssh

# 显示容器信息
# echo "容器已启动，使用以下命令连接："
# echo "ssh root@localhost -p 10024"
# echo "默认密码: root"
# echo "建议登录后立即更改密码：passwd root"
# ssh root@localhost -p 10024
