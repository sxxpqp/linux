---
name: ci-php
description: "PHP 项目 GitLab CI/CD + Dockerfile 生产模板。PHP-FPM + Nginx 双容器架构，多阶段构建(Kaniko)，含 Composer 依赖管理、环境配置分离、K8s 滚动部署。触发词: php ci, php-fpm ci, php dockerfile, 后端 ci, 写 PHP 流水线, 生成 PHP dockerfile, composer install, thinkphp 部署"
---

# PHP 项目 CI/CD 生产模板

> 提取自 `D:\code\focus` 等真实项目。
> CI 参数风格参考 `D:\code\ad-rtb\.gitlab-ci.yml`（分支感知环境映射）。

## 核心思路

1. **双容器 Pod**: Nginx（静态资源 + 反向代理）+ PHP-FPM（应用逻辑），同 Pod 内通过 `127.0.0.1:9000` 通信
2. **环境配置分离**: `.env.test` / `.env.prod` 按分支选择，通过 `ARG ENV_FILE` 传入 Dockerfile
3. **PHP-FPM 监听 TCP**: `listen = 127.0.0.1:9000`（非 Unix socket），便于同 Pod 内 Nginx 连接
4. **Kaniko 并行构建**: `build-php` 和 `build-nginx` 同 stage 并行，总耗时 = max(php, nginx)
5. **共享 volume**: `emptyDir: webroot`，PHP 写入 `public/`，Nginx 读取静态文件
6. **分支感知环境映射**: test → test namespace + .env.test, release* → uat + .env.test, master → prod + .env.prod
7. **master 手动部署**: deploy 阶段 master 分支只允许 manual

---

## Dockerfile 模板

### PHP-FPM 镜像 — `Dockerfile`

```dockerfile
FROM hub.wishfoxs.com:6443/middleware/php:7.4-fpm

ARG APT_MIRROR=mirrors.aliyun.com

# 替换 Debian 源为阿里云镜像
RUN set -eux; \
    if [ -f /etc/apt/sources.list ]; then \
        sed -i "s|deb.debian.org|${APT_MIRROR}|g; s|security.debian.org|${APT_MIRROR}|g" /etc/apt/sources.list; \
    fi

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    libpng-dev libjpeg-dev libfreetype6-dev libzip-dev \
    unzip git curl zip libonig-dev libxml2-dev libicu-dev \
    && rm -rf /var/lib/apt/lists/*

# 时区配置
RUN apt-get install -y tzdata \
    && ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime \
    && echo "date.timezone = Asia/Shanghai" >> /usr/local/etc/php/conf.d/timezone.ini

# 安装 PHP 扩展
RUN docker-php-ext-install bcmath zip pdo pdo_mysql mbstring xml intl opcache

# 配置并安装 GD 扩展
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install gd

# 安装 Composer
RUN curl -sS https://getcomposer.org/installer | php -- \
    --install-dir=/usr/local/bin --filename=composer

# 创建非 root 用户
RUN groupadd -g 1000 app && \
    useradd -u 1000 -g app -m -s /bin/bash app

WORKDIR /workspace

# 层缓存优化：先拷贝依赖声明
COPY composer.json composer.lock* ./
RUN composer install --no-dev --optimize-autoloader --no-interaction

# 拷贝源码
COPY . .

# 环境配置：通过 ARG 指定，CI 按分支传入
ARG ENV_FILE=.env.test
COPY ${ENV_FILE} .env

# PHP-FPM 监听 TCP，同 Pod 内 Nginx 通过 127.0.0.1:9000 连接
RUN echo "listen = 127.0.0.1:9000" >> /usr/local/etc/php-fpm.d/zz-docker.conf

# 创建运行时目录并设置权限
RUN mkdir -p runtime/cache runtime/log runtime/temp public/uploads \
    && chown -R app:app /workspace

USER app
CMD ["php-fpm"]
```

### Nginx 镜像 — `Dockerfile.nginx`

```dockerfile
FROM hub.wishfoxs.com:6443/middleware/nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

### Nginx 配置 — `nginx.conf`

```nginx
server {
    listen 80;
    server_name _;
    absolute_redirect off;
    root /workspace/public;
    index index.php index.html;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    client_max_body_size 20m;

    # K8s 探针
    location = /healthz {
        access_log off;
        return 200 "ok\n";
    }

    # 压缩
    gzip on;
    gzip_vary on;
    gzip_min_length 1k;
    gzip_comp_level 5;
    gzip_types text/plain text/css application/json application/javascript
               application/xml image/svg+xml font/ttf font/otf;

    # 静态资源缓存
    location ~* ^/assets/.+\.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?|ttf|eot)$ {
        expires 7d;
        access_log off;
    }

    # 路由转发
    location / {
        try_files $uri $uri/ /index.php$is_args$args;
    }

    # PHP-FPM 转发
    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_param PATH_INFO $fastcgi_path_info;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    # 禁止访问隐藏文件和敏感文件
    location ~ /\. { deny all; }
    location ~* \.(env|log|bak|sql|md)$ { deny all; }
}
```

---

## .gitlab-ci.yml 模板

```yaml
# 仅允许在 GitLab 页面/API/trigger 手动触发流水线；master 分支只手动部署
workflow:
  rules:
    - if: '$CI_PIPELINE_SOURCE == "web"'
    - if: '$CI_PIPELINE_SOURCE == "api"'
    - if: '$CI_PIPELINE_SOURCE == "trigger"'

default:
  tags:
    - docker
  before_script:
    - |
      case "${CI_COMMIT_REF_NAME}" in
        test)
          IMAGE_PREFIX="test"
          K8S_NAMESPACE="xxx-test"           # ← 改成实际 namespace
          ENV_FILE=".env.test"
          ;;
        release|release-*)
          IMAGE_PREFIX="uat"
          K8S_NAMESPACE="xxx-uat"            # ← 改成实际 namespace
          ENV_FILE=".env.test"               # ← 有 .env.uat 时改成 .env.uat
          ;;
        master)
          IMAGE_PREFIX="prod"
          K8S_NAMESPACE="xxx"                # ← 改成实际 namespace
          ENV_FILE=".env.prod"               # ← 需要创建 .env.prod
          ;;
        *)
          echo "ERROR: 当前分支 ${CI_COMMIT_REF_NAME} 未配置流水线环境"
          exit 1
          ;;
      esac
      export IMAGE_PREFIX
      export K8S_NAMESPACE
      export ENV_FILE
      export IMAGE_TAG="${IMAGE_PREFIX}-${VERSION}"

stages:
  - build_image
  - deploy

variables:
  KANIKO_IMAGE: "hub.wishfoxs.com:6443/middleware/executor:debug"
  KUBECTL_IMAGE: "hub.wishfoxs.com:6443/middleware/kubectl:latest"
  HARBOR_REGISTRY: "hub.wishfoxs.com:6443"
  HARBOR_PROJECT: "mall"                         # ← 改成本项目的 Harbor 命名空间
  PHP_IMAGE_NAME: "focus"                        # ← 改成 PHP 镜像名
  NGINX_IMAGE_NAME: "focus-nginx"                # ← 改成 Nginx 镜像名
  VERSION:
    value: "1.0.0"
    description: "镜像版本号，例如: 1.0.1（最终 tag 形如 test-1.0.1 / uat-1.0.1 / prod-1.0.1）"
  DEPLOY_TO_K8S:
    value: "true"
    description: "构建完成后是否自动滚动更新 K8s（true/false）"
  K8S_DEPLOYMENT:
    value: "focus"                               # ← 改成 K8s Deployment 名
    description: "K8s 中的 Deployment 名称"

# ============================================================
# Stage 1: Kaniko 构建 PHP-FPM 镜像
# ============================================================
build-php:
  stage: build_image
  image:
    name: $KANIKO_IMAGE
    entrypoint: [""]
  script:
    - mkdir -p /kaniko/.docker
    - |
      cat > /kaniko/.docker/config.json <<EOF
      {"auths":{"${HARBOR_REGISTRY}":{"username":"${HARBOR_USERNAME}","password":"${HARBOR_PASSWORD}"}}}
      EOF
    - |
      echo "===== Kaniko 构建 PHP: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${PHP_IMAGE_NAME}:${IMAGE_TAG} ====="
      echo "ENV_FILE: ${ENV_FILE}"
      /kaniko/executor \
        --context "${CI_PROJECT_DIR}" \
        --dockerfile "${CI_PROJECT_DIR}/Dockerfile" \
        --destination "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${PHP_IMAGE_NAME}:${IMAGE_TAG}" \
        --build-arg "ENV_FILE=${ENV_FILE}" \
        --cache=true \
        --cache-repo "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${PHP_IMAGE_NAME}-cache" \
        --verbosity=info

# ============================================================
# Stage 1: Kaniko 构建 Nginx 镜像（与 PHP 并行）
# ============================================================
build-nginx:
  stage: build_image
  image:
    name: $KANIKO_IMAGE
    entrypoint: [""]
  script:
    - mkdir -p /kaniko/.docker
    - |
      cat > /kaniko/.docker/config.json <<EOF
      {"auths":{"${HARBOR_REGISTRY}":{"username":"${HARBOR_USERNAME}","password":"${HARBOR_PASSWORD}"}}}
      EOF
    - |
      echo "===== Kaniko 构建 Nginx: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${NGINX_IMAGE_NAME}:${IMAGE_TAG} ====="
      /kaniko/executor \
        --context "${CI_PROJECT_DIR}" \
        --dockerfile "${CI_PROJECT_DIR}/Dockerfile.nginx" \
        --destination "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${NGINX_IMAGE_NAME}:${IMAGE_TAG}" \
        --cache=true \
        --cache-repo "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${NGINX_IMAGE_NAME}-cache" \
        --verbosity=info

# ============================================================
# Stage 2: 滚动更新 K8s（两个容器都要更新）
# ============================================================
deploy-k8s:
  stage: deploy
  image:
    name: $KUBECTL_IMAGE
    entrypoint: [""]
  needs:
    - job: build-php
      artifacts: false
    - job: build-nginx
      artifacts: false
  rules:
    - if: '$CI_COMMIT_REF_NAME != "master" && $DEPLOY_TO_K8S == "true"'
      when: on_success
    - when: manual
      allow_failure: true
  cache: []
  script:
    - mkdir -p ~/.kube
    - cp $KUBE_CONFIG ~/.kube/config
    - |
      PHP_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${PHP_IMAGE_NAME}:${IMAGE_TAG}"
      NGINX_IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${NGINX_IMAGE_NAME}:${IMAGE_TAG}"

      echo "===== 发布环境 ====="
      echo "branch=${CI_COMMIT_REF_NAME}"
      echo "namespace=${K8S_NAMESPACE}"
      echo "php_image=${PHP_IMAGE}"
      echo "nginx_image=${NGINX_IMAGE}"

      echo "===== 更新 PHP 容器镜像 ====="
      kubectl set image deployment/${K8S_DEPLOYMENT} \
        php-fpm=${PHP_IMAGE} \
        -n ${K8S_NAMESPACE}

      echo "===== 更新 Nginx 容器镜像 ====="
      kubectl set image deployment/${K8S_DEPLOYMENT} \
        nginx=${NGINX_IMAGE} \
        -n ${K8S_NAMESPACE}

      echo "===== 强制重启 ====="
      kubectl rollout restart deployment/${K8S_DEPLOYMENT} -n ${K8S_NAMESPACE}

      echo "===== 等待滚动更新完成 ====="
      kubectl rollout status deployment/${K8S_DEPLOYMENT} \
        -n ${K8S_NAMESPACE} --timeout=300s
```

---

## K8s Deployment 模板

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: focus
spec:
  replicas: 1
  selector:
    matchLabels:
      app: focus
  template:
    metadata:
      labels:
        app: focus
    spec:
      # 共享 volume: PHP-FPM 的 public/ 通过 initContainer 拷贝过来，Nginx 读取静态文件
      volumes:
        - name: webroot
          emptyDir: {}
      # initContainer: 把 PHP 镜像里的 /workspace/public 拷贝到 emptyDir（否则 emptyDir 是空的，会覆盖镜像文件）
      initContainers:
        - name: copy-public
          image: hub.wishfoxs.com:6443/mall/focus:test-1.0.0
          command: ['sh', '-c', 'cp -r /workspace/public/* /public/']
          volumeMounts:
            - name: webroot
              mountPath: /public
      containers:
        # Nginx 容器
        - name: nginx
          image: hub.wishfoxs.com:6443/mall/focus-nginx:test-1.0.0
          ports:
            - containerPort: 80
          volumeMounts:
            - name: webroot
              mountPath: /workspace/public
              readOnly: true
          livenessProbe:
            httpGet:
              path: /healthz
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi

        # PHP-FPM 容器
        - name: php-fpm
          image: hub.wishfoxs.com:6443/mall/focus:test-1.0.0
          ports:
            - containerPort: 9000
          volumeMounts:
            - name: webroot
              mountPath: /var/www/html/public
          livenessProbe:
            tcpSocket:
              port: 9000
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: focus
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 80
  selector:
    app: focus
```

---

## 反模式表

| ✗ 错误做法 | ✓ 正确做法 | 原因 |
|---|---|---|
| 单容器跑 Nginx + PHP-FPM | 双容器 Pod，独立镜像 | 独立扩缩容、资源隔离、职责分离 |
| PHP-FPM 监听 Unix socket | `listen = 127.0.0.1:9000` | 同 Pod 内 TCP 更稳定，便于健康检查 |
| `.env` 硬编码在仓库 | `.env.test` / `.env.prod` 按分支选择 | 环境配置分离，同一镜像跑多环境 |
| `COPY .env .env` 固定文件 | `ARG ENV_FILE=.env.test` + `COPY ${ENV_FILE} .env` | CI 按分支传入不同配置文件 |
| Nginx 和 PHP 分开部署 | 同 Pod，`emptyDir` 共享 `public/` | 同 Pod 通信零延迟，共享文件简单 |
| `kubectl apply -f deployment.yaml` | `kubectl set image` + `rollout restart` | 幂等，不依赖 yaml 文件 |
| push 自动触发 CI | `workflow: rules: [web, api, trigger]` | 避免无效构建，手动控制发布节奏 |
| 镜像 tag 不带环境前缀 | `IMAGE_TAG="${IMAGE_PREFIX}-${VERSION}"` | 多环境部署时无法区分 test/uat/prod |
| master 分支自动部署 | `if: '$CI_COMMIT_REF_NAME != "master"'` + manual | 生产环境必须手动确认 |

---

## 检查清单(生成前自查)

- [ ] Dockerfile 基础镜像走 `hub.wishfoxs.com:6443/middleware/...`
- [ ] PHP-FPM 监听 `127.0.0.1:9000`（非 Unix socket）
- [ ] 非 root 用户运行（`USER app` 或 `USER 1000:1000`）
- [ ] 时区设置 `Asia/Shanghai`
- [ ] 环境配置通过 `ARG ENV_FILE` 传入，不硬编码
- [ ] Nginx 配置有 `/healthz` 探针
- [ ] Nginx 配置有 `fastcgi_pass 127.0.0.1:9000`
- [ ] Nginx 配置有静态资源缓存
- [ ] 双镜像并行构建：`build-php` + `build-nginx` 同 stage
- [ ] .gitlab-ci.yml 有 `workflow: rules` 限制手动触发
- [ ] .gitlab-ci.yml 有 `before_script` 分支感知环境映射（case 语句）
- [ ] 分支映射同时决定 `IMAGE_PREFIX` / `K8S_NAMESPACE` / `ENV_FILE`
- [ ] .gitlab-ci.yml Kaniko auth 正确（`/kaniko/.docker/config.json`）
- [ ] .gitlab-ci.yml 有 `--build-arg "ENV_FILE=${ENV_FILE}"`
- [ ] 镜像 tag 格式 `${IMAGE_PREFIX}-${VERSION}`（test-1.0.1 / uat-1.0.1 / prod-1.0.1）
- [ ] master 分支 deploy 只允许 manual
- [ ] K8s Deployment 有 `emptyDir: webroot` 共享 volume
- [ ] K8s Deployment 有两个容器：`nginx` + `php-fpm`
- [ ] 变量 `HARBOR_PROJECT` / `PHP_IMAGE_NAME` / `NGINX_IMAGE_NAME` / `K8S_DEPLOYMENT` / namespace 已替换为本项目值

---

## 何时调用此 skill

- 用户说"给 PHP 项目写 CI" / "生成 PHP-FPM Dockerfile"
- 用户提到 `composer.json` + `public/index.php`
- 用户的项目目录有 `composer.json` 且 type 为 `project`
- 用户说"ThinkPHP / Laravel 怎么部署到 K8s"
- 用户说"PHP 项目需要 Nginx + PHP-FPM 双容器"
