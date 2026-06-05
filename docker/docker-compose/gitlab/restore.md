# GitLab 从 MinIO 备份恢复

> 新机器从零恢复 GitLab, 数据源 MinIO `s3://gitlab/`。
> 已验证: GitLab CE 18.4.0

## TL;DR

```bash
# 设变量
HOST_IP=172.16.150.100         # 新机器 IP
BACKUP=1778206527_2026_05_08_18.4.0  # 备份文件名(去掉 .tar)
VERSION=18.4.0-ce.0
MINIO="http://58.49.56.57:8060"

# 一键执行
curl -fsSL https://get.docker.com | sh
mkdir -p /home/gitlab/{etc,log,opt/backups}

# 下配置 + 备份
aws s3 cp s3://gitlab/gitlab-config/gitlab-secrets.json /home/gitlab/etc/ --endpoint-url $MINIO
aws s3 cp s3://gitlab/gitlab-config/gitlab.rb /home/gitlab/etc/ --endpoint-url $MINIO
aws s3 cp s3://gitlab/${BACKUP}_gitlab_backup.tar /home/gitlab/opt/backups/ --endpoint-url $MINIO

# 启动 → 恢复 → 重启
cd /home/gitlab
docker compose up -d  # compose.yaml 见下方
# 等 3 分钟全部 run 后:
docker exec gitlab gitlab-ctl stop puma sidekiq
chmod 600 /home/gitlab/opt/backups/${BACKUP}_gitlab_backup.tar
docker exec gitlab gitlab-backup restore BACKUP=$BACKUP  # 输两次 yes
docker exec gitlab gitlab-ctl reconfigure && docker exec gitlab gitlab-ctl restart
```

---

## 前提

| 项 | 值 |
|---|---|
| MinIO endpoint | `http://58.49.56.57:8060` |
| 桶 | `gitlab` |
| 必拉配置 | `s3://gitlab/gitlab-config/gitlab-secrets.json` + `gitlab.rb` |
| ⚠ 版本 | **必须一致**, 跨版本恢复会失败 |

## 准备

```bash
# Docker(已装跳过)
curl -fsSL https://get.docker.com | sh

# AWS CLI(已装跳过, 需配 MinIO 凭证)
aws configure  # 输入 AK/SK + region

# 目录
mkdir -p /home/gitlab/{etc,log,opt/backups}
```

## docker-compose.yaml

```yaml
# /home/gitlab/docker-compose.yaml
services:
  gitlab:
    image: gitlab/gitlab-ce:18.4.0-ce.0
    container_name: gitlab
    restart: always
    hostname: 'GITLAB_IP'          # ← 改成实际 IP
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://GITLAB_IP:9980'   # ← 同上
        gitlab_rails['gitlab_shell_ssh_port'] = 9922
    ports:
      - '9980:9980'
      - '9922:22'
    volumes:
      - /home/gitlab/etc:/etc/gitlab
      - /home/gitlab/log:/var/log/gitlab
      - /home/gitlab/opt:/var/opt/gitlab
    shm_size: '256m'
```

## 恢复流程

``bash
HOST_IP=172.16.150.100
BACKUP=1778206527_2026_05_08_18.4.0
MINIO="http://58.49.56.57:8060"

# 1. 下载
aws s3 cp s3://gitlab/gitlab-config/ /home/gitlab/etc/ --recursive --endpoint-url $MINIO
aws s3 cp s3://gitlab/${BACKUP}_gitlab_backup.tar /home/gitlab/opt/backups/ --endpoint-url $MINIO

# 2. 启动 + 等就绪(约 3 分钟)
cd /home/gitlab
docker compose up -d
# 循环等所有服务 run:
until docker exec gitlab gitlab-ctl status | grep -qv 'down\|fail'; do sleep 10; done

# 3. 停服务 → 恢复
docker exec gitlab gitlab-ctl stop puma sidekiq
docker exec gitlab gitlab-backup restore BACKUP=$BACKUP   # 输 yes 两次

# 4. 重启
docker exec gitlab gitlab-ctl reconfigure
docker exec gitlab gitlab-ctl restart
docker exec gitlab gitlab-rake gitlab:check SANITIZE=true
```

浏览器 `http://$HOST_IP:9980`。

## 踩坑

| 现象 | 原因 | 修法 |
|---|---|---|
| `Permission denied` 恢复失败 | 备份文件权限不对 | `chmod 600` + `chown 998:998` |
| `Version mismatch` | 镜像版本 ≠ 备份版本 | 确认 `docker inspect gitlab \| grep Image` 版本一致 |
| secrets.json 丢失 | 恢复后 CI/CD 变量/runner token 全丢 | 必须先拉 `gitlab-config/` |
| MinIO 连不上 | endpoint 不通或 AK/SK 错 | `aws s3 ls --endpoint-url $MINIO` 测试 |
