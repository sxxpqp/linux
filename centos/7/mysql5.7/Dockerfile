 centos:7

# 替换 yum 源为清华大学镜像
RUN sed -i.bak \
    -e "s|^mirrorlist=http://mirrorlist.centos.org/|#mirrorlist=http://mirrorlist.centos.org/|g" \
    -e "s|^#baseurl=http://mirror.centos.org/centos/\$releasever|baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos-vault/7.9.2009|g" \
    -e "s|^#baseurl=http://mirror.centos.org/\$contentdir/\$releasever|baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos-vault/7.9.2009|g" \
    /etc/yum.repos.d/CentOS-Base.repo

# 安装 wget 并清理缓存
RUN yum -y install wget numactl-libs  net-tools  perl libaio
RUN wget  https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/mysql5.7/mysql-community-libs-5.7.44-1.el7.x86_64.rpm && wget https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/mysql5.7/mysql-community-client-5.7.44-1.el7.x86_64.rpm && wget  https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/mysql5.7/mysql-community-common-5.7.44-1.el7.x86_64.rpm && wget https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/mysql5.7/mysql-community-server-5.7.44-1.el7.x86_64.rpm
RUN  rpm -ivh mysql-*.rpm

# 创建 MySQL 数据目录
RUN mkdir -p /var/lib/mysql && \
    chown -R mysql:mysql /var/lib/mysql
USER mysql
# 暴露 MySQL 端口
EXPOSE 3306

# 初始化 MySQL 数据库
RUN mysqld --initialize-insecure --user=mysql

# 启动 MySQL 服务
CMD ["mysqld"]



### 构建
## docker build -t  centos:7-mysql5.7 .

### 启动 密码为空
##  docker run -d --name mysql_container -p 3306:3306 --user mysql centos:7-mysql5.7
