#!/bin/bash
# CentOS 7 切换 yum 源为阿里云镜像
# 用法(推荐): curl -fsSL https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/centos/switch-aliyun-mirror.sh | bash
# 或者本地: bash switch-aliyun-mirror.sh

set -e

# 检查系统
if [ ! -f /etc/redhat-release ]; then
    echo "❌ 不是 CentOS/RHEL 系统"
    exit 1
fi

if ! grep -q "CentOS Linux release 7" /etc/centos-release 2>/dev/null; then
    echo "⚠️  不是 CentOS 7，脚本只验证过 CentOS 7"
fi

REPO_FILE="/etc/yum.repos.d/CentOS-Base.repo"
BACKUP_FILE="/etc/yum.repos.d/CentOS-Base.repo.bak.$(date +%Y%m%d%H%M%S)"

# 备份
if [ -f "$REPO_FILE" ]; then
    cp "$REPO_FILE" "$BACKUP_FILE"
    echo "✅ 已备份: $BACKUP_FILE"
fi

# 替换为阿里云源
sed -i \
  -e 's|^mirrorlist=|#mirrorlist=|g' \
  -e 's|^#baseurl=http://mirror.centos.org|baseurl=http://mirrors.aliyun.com|g' \
  -e 's|^#baseurl=http://vault.centos.org|baseurl=http://mirrors.aliyun.com|g' \
  "$REPO_FILE"

# 如果上面 sed 没匹配到（可能是全新系统默认没有 baseurl），直接写入阿里云配置
if ! grep -q "mirrors.aliyun.com" "$REPO_FILE" 2>/dev/null; then
    cat > "$REPO_FILE" << 'EOF'
# CentOS-Base.repo — 阿里云镜像 (自动生成)
[base]
name=CentOS-$releasever - Base - mirrors.aliyun.com
baseurl=http://mirrors.aliyun.com/centos/$releasever/os/$basearch/
        http://mirrors.aliyuncs.com/centos/$releasever/os/$basearch/
gpgcheck=1
gpgkey=http://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[updates]
name=CentOS-$releasever - Updates - mirrors.aliyun.com
baseurl=http://mirrors.aliyun.com/centos/$releasever/updates/$basearch/
        http://mirrors.aliyuncs.com/centos/$releasever/updates/$basearch/
gpgcheck=1
gpgkey=http://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7

[extras]
name=CentOS-$releasever - Extras - mirrors.aliyun.com
baseurl=http://mirrors.aliyun.com/centos/$releasever/extras/$basearch/
        http://mirrors.aliyuncs.com/centos/$releasever/extras/$basearch/
gpgcheck=1
gpgkey=http://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
EOF
fi

# 清理缓存并测试
yum clean all
yum makecache

echo ""
echo "🎉 CentOS yum 源已切换到阿里云镜像!"
echo "   备份文件: $BACKUP_FILE"
echo "   恢复命令: mv $BACKUP_FILE $REPO_FILE && yum clean all && yum makecache"
