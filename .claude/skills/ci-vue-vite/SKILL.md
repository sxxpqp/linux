---
name: ci-vue-vite
description: "Vue + Vite 前端项目 GitLab CI/CD + Dockerfile 生产模板。覆盖 Vue3+Vite+pnpm/npm、uni-app、Nuxt 变体，含环境变量注入(--mode / node build.js 多入口)两种构建模式。多阶段构建(Kaniko)→ Nginx SPA 运行时，含 gzip 预压缩、层缓存优化、K8s 滚动部署。触发词: vue ci, vite ci, 前端 ci, frontend ci, vue dockerfile, 前端 dockerfile, uni-app ci, nuxt ci, spa ci, 写前端流水线, 生成前端 dockerfile, npm build, pnpm build"
---

# Vue + Vite 前端 CI/CD 生产模板

> 提取自 `D:\code\admin`、`D:\code\sohu-admin`、`D:\code\dsp-web` 等 30+ 个真实项目。
> CI 参数风格参考 `D:\code\ad-rtb\.gitlab-ci.yml`（分支感知环境映射）。

## 核心思路

1. **多阶段构建**: build 阶段装依赖 + Vite 构建 → runtime 阶段只拷贝 dist + nginx
2. **层缓存优化**: 先 COPY package.json/pnpm-lock.yaml → install → 再 COPY 源码，lockfile 不变时命中缓存
3. **gzip 预压缩**: 构建期 gzip 所有静态资源(>1KB)，运行时 nginx `gzip_static on` 零 CPU 开销
4. **Kaniko 构建**: 无 Docker daemon，rootless，`--cache=true --cache-repo` 推送到 Harbor
5. **SPA fallback**: nginx `try_files $uri $uri/ /index.html` 支持 history 路由
6. **分支感知环境映射**: test → test namespace, release* → uat namespace, master → prod namespace(手动部署)

---

## 构建模式决策: 先分两种情况

动手写 Dockerfile 前，先看 `package.json` 的 `scripts.build`，判断属于哪种，再套对应模板：

| 情况 | 判定标准 | 构建命令 |
|---|---|---|
| **A. 无环境变量注入** | `build` 就是裸 `vite build` / `vue-cli-service build`，无 `--mode`、无自定义 build 脚本 | 直接 `pnpm/npm run build`（下面主模板） |
| **B. 有环境变量注入** | `build` 带 `--mode <x>`，或依赖 `cross-env VITE_MODE=... node build.js` | 按下面优先级选 |

**B 情况优先级（从高到低）：**

1. **优先 `vite build --mode <mode>`**：项目是标准 Vite 工程，只是靠 `.env.<mode>` 切换环境。构建命令写成 `npm run build -- --mode ${BUILD_MODE}`（或直接 `vite build --mode ${BUILD_MODE}`），Dockerfile 里 `case` 把 `BUILD_MODE` 映射成 `staging/pre/production`。
2. **最后手段 `node build.js`**：项目自带构建编排脚本（多入口、多产物 `dist/web`/`dist/app`、自定义 env 映射），必须靠 `BUILD_TYPE` / `BUILD_TAG` / `VITE_MODE` 等环境变量驱动，才走 `node build.js`（见下方「自定义 build.js」变体）。

> 判断原则：**能用 `--mode` 就不要上 `node build.js`**。`--mode` 是 Vite 原生环境加载机制，可移植、可缓存；`build.js` 是项目私有编排，只在多入口/非标准产物时才需要。

---

## Dockerfile 模板

```dockerfile
# ---------- Build Stage ----------
FROM hub.wishfoxs.com:6443/middleware/node:22.21-alpine AS build
WORKDIR /app

# 1. 先拷贝依赖声明，利用层缓存
COPY package.json pnpm-lock.yaml* ./

# 2. 装 pnpm + 依赖（npm 镜像加速）
RUN npm config set registry https://registry.npmmirror.com \
 && npm install -g pnpm@9 \
 && (pnpm install --frozen-lockfile || pnpm install)

# 3. 拷贝源码
COPY . .

# 4. 防 OOM + 构建 + gzip 预压缩
ENV NODE_OPTIONS="--max-old-space-size=4096"
RUN pnpm run build \
 && find dist -type f \( \
        -name '*.js'   -o -name '*.css'  -o -name '*.html' \
     -o -name '*.svg'  -o -name '*.json' -o -name '*.xml'  \
     -o -name '*.txt'  -o -name '*.ico'  -o -name '*.map'  \
    \) -size +1k -exec sh -c 'for file do [ -e "$file.gz" ] || gzip -9 -k "$file"; done' sh {} + \
 && echo "===== dist size =====" \
 && du -sh dist

# ---------- Runtime Stage ----------
FROM hub.wishfoxs.com:6443/middleware/nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
```

### 变体: npm 项目(无 pnpm-lock.yaml)

```dockerfile
COPY package.json package-lock.json* ./
RUN npm config set registry https://registry.npmmirror.com \
 && npm ci || npm install
# ...
RUN npm run build
```

### 变体: uni-app 项目

```dockerfile
RUN pnpm run build:mp-weixin  # 或 build:h5
# 产物目录可能是 dist/build/mp-weixin
```

### 变体 B1: 环境变量注入 → `--mode`（优先）

> 标准 Vite 工程，只是用 `.env.staging` / `.env.pre` / `.env.production` 切换环境。
> CI 只传一个 `--build-arg BUILD_MODE`，Dockerfile 里 `case` 映射成具体 mode。

```dockerfile
ARG BUILD_MODE=production
RUN npm run build -- --mode ${BUILD_MODE}
```

Dockerfile 里 `case` 映射（配合 CI 的 `BUILD_MODE`）：

```dockerfile
RUN case "${BUILD_MODE}" in \
      staging)   VITE_MODE=staging ;; \
      pre)       VITE_MODE=pre ;; \
      production) VITE_MODE=production ;; \
      *) echo "Unsupported BUILD_MODE: ${BUILD_MODE}" && exit 1 ;; \
    esac \
 && npm run build -- --mode ${VITE_MODE}
```

### 变体 B2: 自定义 build.js（最后手段，多入口/多产物）

> 来源 `D:\code\xet-live-h5`。项目自带 `node build.js` 编排构建：`BUILD_TYPE` 选入口(web/app)、`VITE_MODE` 选环境，产物 `dist/web` / `dist/app`。
> 注意 `.npmrc` 私有源必须一起 COPY，否则 `@xiaoe/*` 等私有包装不上。

```dockerfile
# ---------- 构建阶段 ----------
FROM hub.wishfoxs.com:6443/middleware/node:20-alpine AS build
WORKDIR /app

# 1. 私有源配置 + 依赖声明一起拷，锁文件不变命中缓存
COPY package.json pnpm-lock.yaml* .npmrc ./

RUN npm install -g pnpm@9 \
 && if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile; else pnpm install --no-frozen-lockfile; fi

# 2. 拷源码
COPY . .

# 构建环境: test / staging / production，由 CI 的 --build-arg 传入，默认 test
ARG BUILD_MODE=test
ARG NODE_MAX_OLD_SPACE_SIZE=8192
ENV NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE}"

# 3. 复用项目 build.js，仅构建 web 入口，输出 dist/web
RUN case "${BUILD_MODE}" in \
      test)       BUILD_TAG=test;       VITE_MODE=test ;; \
      staging)    BUILD_TAG=staging;    VITE_MODE=staging ;; \
      production) BUILD_TAG=production; VITE_MODE=production ;; \
      *) echo "Unsupported BUILD_MODE: ${BUILD_MODE}" && exit 1 ;; \
    esac \
 && BUILD_TYPE=web BUILD_TAG="${BUILD_TAG}" VITE_MODE="${VITE_MODE}" node build.js \
 && find dist/web -type f \( \
        -name '*.js'   -o -name '*.css'  -o -name '*.html' \
     -o -name '*.svg'  -o -name '*.json' -o -name '*.xml'  \
     -o -name '*.txt'  -o -name '*.ico'  -o -name '*.map'  \
    \) -size +1k -exec gzip -9 -k {} + \
 && echo "===== dist/web 体积 =====" \
 && du -sh dist/web/

# ---------- 托管阶段 ----------
FROM hub.wishfoxs.com:6443/middleware/nginx:1.27-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/web /usr/share/nginx/html

EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
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
          ;;
        release|release-*)
          IMAGE_PREFIX="uat"
          K8S_NAMESPACE="xxx-uat"            # ← 改成实际 namespace
          ;;
        master)
          IMAGE_PREFIX="prod"
          K8S_NAMESPACE="xxx"                # ← 改成实际 namespace
          ;;
        *)
          echo "ERROR: 当前分支 ${CI_COMMIT_REF_NAME} 未配置流水线环境"
          exit 1
          ;;
      esac
      export IMAGE_PREFIX
      export K8S_NAMESPACE
      export IMAGE_TAG="${IMAGE_PREFIX}-${VERSION}"

stages:
  - build_image
  - deploy

variables:
  KANIKO_IMAGE: "hub.wishfoxs.com:6443/middleware/executor:debug"
  KUBECTL_IMAGE: "hub.wishfoxs.com:6443/middleware/kubectl:latest"
  HARBOR_REGISTRY: "hub.wishfoxs.com:6443"
  HARBOR_PROJECT: "hmt"                          # ← 改成本项目的 Harbor 命名空间
  IMAGE_NAME: "hmt-admin"                        # ← 改成镜像名
  VERSION:
    value: "1.0.0"
    description: "镜像版本号，例如: 1.0.1（最终 tag 形如 test-1.0.1 / uat-1.0.1 / prod-1.0.1）"
  DEPLOY_TO_K8S:
    value: "true"
    description: "构建完成后是否自动滚动更新 K8s（true/false）"
  K8S_DEPLOYMENT:
    value: "hmt-admin"                           # ← 改成 K8s Deployment 名
    description: "K8s 中的 Deployment 名称"

# ============================================================
# Stage 1: Kaniko 多阶段构建 + 推镜像
# ============================================================
build-image:
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
      echo "===== Kaniko 构建: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG} ====="
      /kaniko/executor \
        --context "${CI_PROJECT_DIR}" \
        --dockerfile "${CI_PROJECT_DIR}/Dockerfile" \
        --destination "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG}" \
        --cache=true \
        --cache-repo "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}-cache" \
        --verbosity=info

# ============================================================
# Stage 2: 滚动更新 K8s 服务
# ============================================================
deploy-k8s:
  stage: deploy
  image:
    name: $KUBECTL_IMAGE
    entrypoint: [""]
  needs:
    - job: build-image
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
      echo "===== 发布环境 ====="
      echo "branch=${CI_COMMIT_REF_NAME}"
      echo "namespace=${K8S_NAMESPACE}"
      echo "image_tag=${IMAGE_TAG}"

      echo "===== 更新镜像 ====="
      kubectl set image deployment/${K8S_DEPLOYMENT} \
        ${K8S_DEPLOYMENT}=${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG} \
        -n ${K8S_NAMESPACE}

      echo "===== 强制重启 ====="
      kubectl rollout restart deployment/${K8S_DEPLOYMENT} -n ${K8S_NAMESPACE}

      echo "===== 等待滚动更新完成 ====="
      kubectl rollout status deployment/${K8S_DEPLOYMENT} \
        -n ${K8S_NAMESPACE} --timeout=300s
```

> **B 情况（环境变量注入）额外两步**：`before_script` 的 `case` 里加一行 `BUILD_MODE`（如 `test→staging / release*→pre / master→production`），并 `export BUILD_MODE`；`build-image` 的 `/kaniko/executor` 追加 `--build-arg "BUILD_MODE=${BUILD_MODE}"`。其余不变。

---

## nginx.conf 模板

```nginx
server {
    listen      8080;
    server_name _;
    absolute_redirect off;
    root  /usr/share/nginx/html;

    # ============ I/O 调优 ============
    sendfile      on;
    tcp_nopush    on;
    tcp_nodelay   on;
    open_file_cache          max=10000 inactive=60s;
    open_file_cache_valid    60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors   on;
    keepalive_timeout  65;
    keepalive_requests 1000;
    client_max_body_size        10m;
    client_body_buffer_size     16k;
    large_client_header_buffers 4 16k;

    # ============ K8s 探针 ============
    location = /healthz {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "ok\n";
    }

    # ============ 压缩 ============
    gzip_static on;  # 优先吐构建期预压缩的 .gz
    gzip            on;
    gzip_vary       on;
    gzip_min_length 1k;
    gzip_comp_level 5;
    gzip_types      text/plain text/css text/xml
                    application/json application/javascript application/xml
                    image/svg+xml font/ttf font/otf;

    # ============ 缓存策略 ============
    # Vite hash 化静态资源 → 1 年长缓存
    location ~* ^/(js|css|img|fonts|media)/.+\.[0-9a-f]+\.(js|css|png|jpe?g|gif|svg|woff2?|ttf|eot|otf|mp4|webm|ogg|mp3|wav)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # index.html 不缓存，发版即时生效
    location = /index.html {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
    }

    # SPA history 路由 fallback
    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

---

## 反模式表

| ✗ 错误做法 | ✓ 正确做法 | 原因 |
|---|---|---|
| `FROM node:latest` | `FROM hub.wishfoxs.com:6443/middleware/node:22.21-alpine` | 走 Harbor mirror，固定版本 |
| 单阶段构建，运行时镜像带 node + 源码 | 多阶段构建，运行时只留 nginx + dist | 镜像体积 1GB → 50MB |
| `COPY . .` 在 `npm install` 前 | 先 `COPY package.json` → install → 再 `COPY .` | 层缓存失效，每次全量 install |
| 运行时 nginx `gzip on` 压缩所有请求 | 构建期 `gzip -9 -k` 预压缩 + `gzip_static on` | 运行时压缩耗 CPU，预压缩零开销 |
| `npm install` 不走镜像 | `npm config set registry https://registry.npmmirror.com` | 国内直连 npmjs.org 慢/不通 |
| `kubectl apply -f deployment.yaml` | `kubectl set image` + `rollout restart` | 幂等，不依赖 yaml 文件 |
| push 自动触发 CI | `workflow: rules: [web, api, trigger]` | 避免无效构建，手动控制发布节奏 |
| 没设 `NODE_OPTIONS` | `ENV NODE_OPTIONS="--max-old-space-size=4096"` | Vite 构建大项目 OOM |
| 没写 `/healthz` 探针 | nginx 加 `location = /healthz { return 200 "ok\n"; }` | K8s liveness/readiness 探针需要 |
| 镜像 tag 不带环境前缀 | `IMAGE_TAG="${IMAGE_PREFIX}-${VERSION}"` | 多环境部署时无法区分 test/uat/prod |
| master 分支自动部署 | `if: '$CI_COMMIT_REF_NAME != "master"'` + manual | 生产环境必须手动确认 |

---

## 检查清单(生成前自查)

- [ ] Dockerfile 基础镜像走 `hub.wishfoxs.com:6443/middleware/...`
- [ ] 多阶段构建，运行时只留 nginx + dist
- [ ] 层缓存优化：先 COPY lockfile → install → 再 COPY 源码
- [ ] gzip 预压缩脚本正确（覆盖 .js/.css/.html/.svg/.json 等）
- [ ] nginx.conf 有 `/healthz` 探针
- [ ] nginx.conf 有 `gzip_static on`
- [ ] nginx.conf 有 SPA fallback `try_files $uri $uri/ /index.html`
- [ ] .gitlab-ci.yml 有 `workflow: rules` 限制手动触发
- [ ] .gitlab-ci.yml 有 `before_script` 分支感知环境映射（case 语句）
- [ ] .gitlab-ci.yml Kaniko auth 正确（`/kaniko/.docker/config.json`）
- [ ] .gitlab-ci.yml 有 `--cache=true --cache-repo`
- [ ] 镜像 tag 格式 `${IMAGE_PREFIX}-${VERSION}`（test-1.0.1 / uat-1.0.1 / prod-1.0.1）
- [ ] master 分支 deploy 只允许 manual
- [ ] 先判断构建模式：A 无环境变量 → 直接 `run build`；B 有环境变量 → 优先 `--mode`，最后才 `node build.js`
- [ ] 变量 `HARBOR_PROJECT` / `IMAGE_NAME` / `K8S_DEPLOYMENT` / namespace 已替换为本项目值
- [ ] （B 情况）CI `before_script` 已映射并 export `BUILD_MODE`，kaniko 已传 `--build-arg BUILD_MODE`
- [ ] （B2 变体）私有源 `.npmrc` 已随依赖声明一起 COPY；产物目录（`dist/web` 等）与 `COPY --from=build` 一致

---

## 何时调用此 skill

- 用户说"给 Vue 项目写 CI" / "生成前端 Dockerfile" / "uni-app 怎么部署"
- 用户提到 `package.json` + `vite.config.js` / `vue.config.js`
- 用户的项目目录有 `package.json` 且 dependencies 里有 `vue` / `vite`
- 用户说"前端项目怎么构建镜像" / "SPA 怎么部署到 K8s"
- 项目 `build` 脚本带 `--mode` / `cross-env VITE_MODE=...` / `node build.js`（环境变量注入 + 多入口）
