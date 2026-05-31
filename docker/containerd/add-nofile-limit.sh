# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/containerd/add-nofile-limit.sh
# 备份原文件
cp /etc/security/limits.conf /etc/security/limits.conf.bak

# 使用 sed 删除已有的 nofile 配置（防止重复），并在末尾追加新值
sed -i '/nofile/d' /etc/security/limits.conf
sed -i '$a * soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576' /etc/security/limits.conf
