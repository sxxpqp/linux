#!/bin/bash
# 自动修复docker.socket相关问题

# 检查docker组
if ! getent group docker > /dev/null; then
    groupadd -r docker
    echo "已创建docker组"
fi

# 检查socket配置
if ! grep -q "SocketGroup=docker" /lib/systemd/system/docker.socket; then
    sed -i 's/SocketGroup=.*/SocketGroup=docker/' /lib/systemd/system/docker.socket
    echo "已修复docker.socket配置"
    
fi

# 修复socket权限
chown root:docker /var/run/docker.sock
chmod 660 /var/run/docker.sock
echo "已修复docker.sock权限"

# 重启socket
systemctl daemon-reload
systemctl restart docker.socket
echo "已重启docker.socket"