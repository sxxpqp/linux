---
name: ci-php
description: Use when a repository contains composer.json and a PHP application with public/index.php and the user asks for GitLab CI, PHP-FPM/Nginx containers, image publishing, or Kubernetes deployment. Do not use for non-PHP projects.
---

# PHP CI/CD

公共流水线、ACR、Kaniko、分支映射和 Kubernetes 发布使用 `ci-gitlab-kaniko`。

## 架构

默认使用同一 Pod 的 PHP-FPM + Nginx 双容器，通过 `127.0.0.1:9000` 通信；用 `emptyDir` 共享需要由 PHP 生成且由 Nginx 读取的 public 资源。确认应用是否真的需要共享 volume，不要无条件套用。

## PHP-FPM Dockerfile

```dockerfile
FROM php:8.2-fpm-bookworm
WORKDIR /workspace
RUN apt-get update && apt-get install -y --no-install-recommends \
      libpng-dev libjpeg-dev libfreetype6-dev libzip-dev unzip \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd pdo_mysql zip opcache \
    && rm -rf /var/lib/apt/lists/*
COPY --from=composer:2.7 /usr/bin/composer /usr/bin/composer
COPY composer.json composer.lock* ./
RUN composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction
COPY . .
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid app --create-home app \
    && mkdir -p runtime/cache runtime/log runtime/temp public/uploads \
    && chown -R 10001:10001 /workspace
RUN printf '%s\n' 'listen = 127.0.0.1:9000' >> /usr/local/etc/php-fpm.d/zz-docker.conf
USER 10001:10001
CMD ["php-fpm"]
```

Composer 依赖必须使用 lockfile。不要使用 `curl ... | php`；Composer 版本通过固定的官方 Composer image 复制，或使用下载后校验的安装方式。

## 配置和秘密

生产镜像**不包含 `.env`**。通过 Kubernetes Secret/ConfigMap 在运行时注入；不要用 Docker `ARG ENV_FILE` 把数据库密码、API token 等写进镜像层。旧项目若无法立即迁移，只能作为明确标注的遗留例外单独处理，不得成为新模板默认值。

## Nginx 基线

```nginx
server {
    listen 80;
    root /workspace/public;
    index index.php;
    location = /healthz { return 200 "ok\n"; }
    location / { try_files $uri $uri/ /index.php$is_args$args; }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_pass 127.0.0.1:9000;
    }
    location ~ /\. { deny all; }
    location ~* \.(env|log|bak|sql)$ { deny all; }
}
```

## PHP 专属 CI 参数

```yaml
PHP_VERSION: "8.2"
PHP_IMAGE_NAME: service-name
NGINX_IMAGE_NAME: service-name-nginx
```

两个镜像可在同一 stage 并行构建；deploy job 必须按实际容器名更新两个镜像。公共技能负责 ACR、受保护变量和 rollout status。

## 检查清单

- [ ] PHP-FPM 监听 `127.0.0.1:9000`
- [ ] Composer 使用 lockfile、固定来源，不 pipe 执行远程脚本
- [ ] `.env`/Secret 不进入镜像
- [ ] PHP 和 Nginx 容器的 volume 路径一致
- [ ] 默认非 root UID 10001
- [ ] Nginx 有 `/healthz` 和 PHP 转发
- [ ] 使用 `ci-gitlab-kaniko` 推送 ACR 并等待 rollout

## 何时不要用

不是 PHP Composer 项目，或问题属于通用 Kaniko、K8s YAML、Shell 脚本、Nginx 单容器静态站点时，不调用本技能。
