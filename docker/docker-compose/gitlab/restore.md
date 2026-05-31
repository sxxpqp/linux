从零开始在新机器上恢复
第一步：安装 Docker
bash# CentOS
curl -fsSL https://get.docker.com | sh
systemctl enable docker && systemctl start docker

# 验证
docker --version

第二步：安装 AWS CLI
bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# 配置 MinIO 凭证
aws configure

第三步：创建目录结构
bash
mkdir -p /home/gitlab/{etc,log,opt/backups}

第四步：从 MinIO 下载所有文件
bash
ENDPOINT="http://58.49.56.57:8060"

# 下载配置文件（必须在启动容器之前）
aws s3 cp s3://gitlab/gitlab-config/gitlab-secrets.json \
  /home/gitlab/etc/gitlab-secrets.json --endpoint-url $ENDPOINT

aws s3 cp s3://gitlab/gitlab-config/gitlab.rb \
  /home/gitlab/etc/gitlab.rb --endpoint-url $ENDPOINT

# 下载最新主备份
aws s3 cp s3://gitlab/1778206527_2026_05_08_18.4.0_gitlab_backup.tar \
  /home/gitlab/opt/backups/ --endpoint-url $ENDPOINT

第五步：创建 docker-compose.yaml
bash
cat > /home/gitlab/docker-compose.yaml << 'EOF'
version: '3.8'
services:
  gitlab:
    image: gitlab/gitlab-ce:18.4.0-ce.0
    container_name: gitlab
    restart: always
    hostname: '新机器IP'
    privileged: true
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://新机器IP:9980'
        gitlab_rails['gitlab_shell_ssh_port'] = 9922
    ports:
      - '9980:9980'
      - '9922:22'
    volumes:
      - '/home/gitlab/etc:/etc/gitlab'
      - '/home/gitlab/log:/var/log/gitlab'
      - '/home/gitlab/opt:/var/opt/gitlab'
    shm_size: '256m'
EOF

第六步：启动容器等待就绪
bash
cd /home/gitlab
docker compose up -d

# 等待启动完成，大概 2-3 分钟
watch docker exec gitlab gitlab-ctl status
# 所有服务都是 run 状态后继续

第七步：设置备份文件权限
bash
chmod 600 /home/gitlab/opt/backups/1778206527_2026_05_08_18.4.0_gitlab_backup.tar
chown 998:998 /home/gitlab/opt/backups/1778206527_2026_05_08_18.4.0_gitlab_backup.tar

第八步：停止相关服务
bash
docker exec -it gitlab gitlab-ctl stop puma
docker exec -it gitlab gitlab-ctl stop sidekiq

第九步：执行恢复
bash
docker exec -it gitlab gitlab-backup restore \
  BACKUP=1778206527_2026_05_08_18.4.0
两次提示输入 yes 确认。

第十步：重启验证
bash
docker exec -it gitlab gitlab-ctl reconfigure
docker exec -it gitlab gitlab-ctl restart

# 检查是否正常
docker exec -it gitlab gitlab-rake gitlab:check SANITIZE=true
浏览器访问 http://新机器IP:9980 确认数据完整。



