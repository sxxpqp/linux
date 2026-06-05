# 从 MinIO 备份在新机器上恢复 GitLab

> 源: https://github.com/sxxpqp/linux/blob/main/docker/docker-compose/gitlab/restore.md
> 状态: 验证过

新机器上从零拉起 GitLab,数据从 MinIO 上的备份恢复。

## 前提

| 项 | 值 |
|---|---|
| 备份位置 | MinIO `s3://gitlab/` 桶 |
| MinIO endpoint | `http://58.49.56.57:8060` |
| 备份文件名格式 | `<unix_timestamp>_YYYY_MM_DD_<gitlab-version>_gitlab_backup.tar` |
| 配套必拉 | `gitlab-config/gitlab-secrets.json`、`gitlab-config/gitlab.rb` |
| GitLab 版本 | 必须**完全一致**(本例 18.4.0-ce.0) |

⚠ 备份只能恢复到**相同版本**的 GitLab — 跨版本恢复会失败。

---

## 第 1 步:安装 Docker

```bash
# CentOS
curl -fsSL https://get.docker.com | sh
systemctl enable docker && systemctl start docker

# 验证
docker --version
```

## 第 2 步:安装 AWS CLI(用 S3 API 访问 MinIO)

```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# 配置 MinIO 凭证
aws configure
```

## 第 3 步:创建目录结构

```bash
mkdir -p /home/gitlab/{etc,log,opt/backups}
```

## 第 4 步:从 MinIO 下载所有文件

```bash
ENDPOINT="http://58.49.56.57:8060"

# 下载配置文件(必须在启动容器之前)
aws s3 cp s3://gitlab/gitlab-config/gitlab-secrets.json \
  /home/gitlab/etc/gitlab-secrets.json --endpoint-url $ENDPOINT

aws s3 cp s3://gitlab/gitlab-config/gitlab.rb \
  /home/gitlab/etc/gitlab.rb --endpoint-url $ENDPOINT

# 下载最新主备份(改成你实际的文件名)
aws s3 cp s3://gitlab/1778206527_2026_05_08_18.4.0_gitlab_backup.tar \
  /home/gitlab/opt/backups/ --endpoint-url $ENDPOINT
```

## 第 5 步:创建 `docker-compose.yaml`

```bash
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
```

## 第 6 步:启动容器,等待就绪

```bash
cd /home/gitlab
docker compose up -d

# 等待启动完成,大概 2-3 分钟
watch docker exec gitlab gitlab-ctl status
# 所有服务都是 run 状态后继续
```

## 第 7 步:设置备份文件权限

```bash
chmod 600 /home/gitlab/opt/backups/1778206527_2026_05_08_18.4.0_gitlab_backup.tar
chown 998:998 /home/gitlab/opt/backups/1778206527_2026_05_08_18.4.0_gitlab_backup.tar
```

## 第 8 步:停止相关服务

```bash
docker exec -it gitlab gitlab-ctl stop puma
docker exec -it gitlab gitlab-ctl stop sidekiq
```

## 第 9 步:执行恢复

```bash
docker exec -it gitlab gitlab-backup restore \
  BACKUP=1778206527_2026_05_08_18.4.0
```

> 两次提示输入 `yes` 确认。

## 第 10 步:重启验证

```bash
docker exec -it gitlab gitlab-ctl reconfigure
docker exec -it gitlab gitlab-ctl restart

# 检查是否正常
docker exec -it gitlab gitlab-rake gitlab:check SANITIZE=true
```

浏览器访问 `http://新机器IP:9980` 确认数据完整。
