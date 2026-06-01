#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/longhorn/install-prerequisites.sh
# 1. 安装 NFS 客户端
apt-get update && apt-get install -y nfs-common

# 2. 临时加载内核模块
modprobe nfs
modprobe dm_crypt

# 3. 配置持久化（重启后依然生效）
tee /etc/modules-load.d/longhorn.conf <<EOF
nfs
dm_crypt
EOF

# 4. 解决 Multipath 警告（Longhorn 建议将其排除或禁用，若不使用多路径建议停止）
systemctl stop multipathd && systemctl disable multipathd
