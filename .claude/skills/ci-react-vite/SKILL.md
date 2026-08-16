---
name: ci-react-vite
description: "React + Vite 前端项目 GitLab CI/CD + Dockerfile 生产模板。多阶段构建(Kaniko)→ Nginx SPA 运行时，含 gzip 预压缩、层缓存优化、K8s 滚动部署。触发词: react ci, vite ci, 前端 ci, frontend ci, react dockerfile, 前端 dockerfile, spa ci, 写前端流水线, 生成前端 dockerfile, npm build, pnpm build, react 部署"
---

# React + Vite 前端 CI/CD 生产模板

> 提取自 `D:\code\admin`、`D:\code\sohu-admin` 等 30+ 个真实项目（Vue/React 共享模板）。
> CI 参数风格参考 `D:\code\ad-rtb\.gitlab-ci.yml`（分支感知环境映射）。

## 核心思路

1. **多阶段构建**: build 阶段装依赖 + Vite 构建 → runtime 阶段只拷贝 dist + nginx
2. **层缓存优化**: 先 COPY package.json/pnpm-lock.yaml → install → 再 COPY 源码，lockfile 不变时命中缓存
3. **gzip 预压缩**: 构建期 gzip 所有静态资源(>1KB)，运行时 nginx `gzip_static on` 零 CPU 开销
4. **Kaniko 构建**: 无 Docker daemon，rootless，`--cache=true --cache-repo` 推送到 Harbor
5. **SPA fallback**: nginx `try_files $uri $uri/ /index.html` 支持 history 路由
6. **分支感知环境映射**: test → test namespace, release* → uat namespace, master → prod namespace(手动部署)

---

## Dockerfile 模板

```dockerfile
# ---------- Build Stage ----------
FROM hub.wishfoxs.com:6443/middleware/node:22.21-alpine AS build
WORKDIR /app

# 1. 先拷贝依赖声明，利用层缓存
COPY package.json pnpm-lock.yaml* ./

# 2. 安装 pnpm（如果用 npm/yarn 则跳过）
RUN corepack enable && corepack prepare pnpm@latest --activate

# 3. 安装依赖（lockfile 不变时命中缓存）
RUN pnpm install --frozen-lockfile

# 4. 拷贝源码
COPY . .

# 5. 构建（React: vite build / Vue: vite build，输出到 dist/）
RUN pnpm build

# 6. gzip 预压缩所有静态资源（>1KB）
RUN apk add --no-cache gzip && \
    find dist -type f -size +1k \( -name "*.js" -o -name "*.css" -o -name "*.html" -o -name "*.svg" -o -name "*.json" \) -exec gzip -k {} \;

# ---------- Runtime Stage ----------
FROM hub.wishfoxs.com:6443/middleware/nginx:1.27-alpine

# 拷贝构建产物
COPY --from=build /app/dist /usr/share/nginx/html

# 拷贝 nginx 配置
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

---

## Nginx 配置模板

```nginx
server {
    listen 80;
    server_name _;

    root /usr/share/nginx/html;
    index index.html;

    # gzip 预压缩
    gzip_static on;
    gzip on;
    gzip_vary on;
    gzip_min_length 1k;
    gzip_comp_level 5;
    gzip_types text/plain text/css application/json application/javascript
               application/xml image/svg+xml font/ttf font/otf;

    # 静态资源缓存（Vite 构建带 hash，可长期缓存）
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?|ttf|eot)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        access_log off;
    }

    # SPA fallback（React Router / Vue Router history 模式）
    location / {
        try_files $uri $uri/ /index.html;
    }

    # K8s 健康检查
    location = /healthz {
        access_log off;
        return 200 "ok\n";
    }
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
  HARBOR_PROJECT: "mall"                         # ← 改成本项目的 Harbor 命名空间
  MODULE: "admin"                                # ← 改成镜像名 / Deployment 名
  VERSION:
    value: "1.0.0"
    description: "镜像版本号，例如: 1.0.1（最终 tag 形如 test-1.0.1 / uat-1.0.1 / prod-1.0.1）"
  DEPLOY_TO_K8S:
    value: "true"
    description: "构建完成后是否自动滚动更新 K8s（true/false）"

# ============================================================
# Stage 1: Kaniko 构建镜像
# ============================================================
build-images:
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
      echo "===== Kaniko 构建: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${MODULE}:${IMAGE_TAG} ====="
      /kaniko/executor \
        --context "${CI_PROJECT_DIR}" \
        --dockerfile "${CI_PROJECT_DIR}/Dockerfile" \
        --destination "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${MODULE}:${IMAGE_TAG}" \
        --cache=true \
        --cache-repo "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${MODULE}-cache" \
        --verbosity=info

# ============================================================
# Stage 2: 滚动更新 K8s
# ============================================================
deploy-k8s:
  stage: deploy
  image:
    name: $KUBECTL_IMAGE
    entrypoint: [""]
  needs:
    - job: build-images
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
      IMAGE="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${MODULE}:${IMAGE_TAG}"

      echo "===== 发布环境 ====="
      echo "branch=${CI_COMMIT_REF_NAME}"
      echo "namespace=${K8S_NAMESPACE}"
      echo "image=${IMAGE}"

      echo "===== 更新镜像 ====="
      kubectl set image deployment/${MODULE} \
        ${MODULE}=${IMAGE} \
        -n ${K8S_NAMESPACE}

      echo "===== 强制重启 ====="
      kubectl rollout restart deployment/${MODULE} -n ${K8S_NAMESPACE}

      echo "===== 等待滚动更新完成 ====="
      kubectl rollout status deployment/${MODULE} \
        -n ${K8S_NAMESPACE} --timeout=300s
```

---

## K8s Deployment 模板

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: admin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: admin
  template:
    metadata:
      labels:
        app: admin
    spec:
      containers:
        - name: admin
          image: hub.wishfoxs.com:6443/mall/admin:test-1.0.0
          ports:
            - containerPort: 80
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
---
apiVersion: v1
kind: Service
metadata:
  name: admin
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 80
  selector:
    app: admin
```

---

## 反模式表

| ✗ 错误做法 | ✓ 正确做法 | 原因 |
|---|---|---|
| `COPY . .` 后再 install | 先 `COPY package.json pnpm-lock.yaml` → install → 再 `COPY` 源码 | 源码改动时不重新 install，层缓存命中 |
| 不做 gzip 预压缩 | 构建期 `find dist -exec gzip -k {} \;` + nginx `gzip_static on` | 零 CPU 开销，首屏加载快 2-3x |
| `nginx:latest` 公共镜像 | `hub.wishfoxs.com:6443/middleware/nginx:1.27-alpine` | 走 Harbor 镜像加速，避免 Docker Hub 拉取失败 |
| `try_files $uri $uri/ /index.html` 缺失 | SPA 必须配置 fallback | React Router / Vue Router history 模式依赖此配置 |
| 静态资源不设缓存 | `expires 1y` + `Cache-Control "public, immutable"` | Vite 构建带 hash，可长期缓存 |
| push 自动触发 CI | `workflow: rules: [web, api, trigger]` | 避免无效构建，手动控制发布节奏 |
| 镜像 tag 不带环境前缀 | `IMAGE_TAG="${IMAGE_PREFIX}-${VERSION}"` | 多环境部署时无法区分 test/uat/prod |
| master 分支自动部署 | `if: '$CI_COMMIT_REF_NAME != "master"'` + manual | 生产环境必须手动确认 |
| 无 `/healthz` 探针 | nginx 配置 `location = /healthz { return 200 "ok\n"; }` | K8s liveness/readiness 探针需要 |

---

## 检查清单(生成前自查)

- [ ] Dockerfile 多阶段构建：build (node:22.21-alpine) → runtime (nginx:1.27-alpine)
- [ ] 基础镜像走 `hub.wishfoxs.com:6443/middleware/...`
- [ ] 层缓存优化：先 `COPY package.json pnpm-lock.yaml` → install → 再 `COPY` 源码
- [ ] gzip 预压缩：`find dist -type f -size +1k -exec gzip -k {} \;`
- [ ] nginx 配置 `gzip_static on`
- [ ] nginx 配置 `try_files $uri $uri/ /index.html`（SPA fallback）
- [ ] nginx 配置静态资源缓存 `expires 1y`
- [ ] nginx 配置 `/healthz` 探针
- [ ] .gitlab-ci.yml 有 `workflow: rules` 限制手动触发
- [ ] .gitlab-ci.yml 有 `before_script` 分支感知环境映射（case 语句）
- [ ] 分支映射同时决定 `IMAGE_PREFIX` / `K8S_NAMESPACE`
- [ ] .gitlab-ci.yml Kaniko auth 正确（`/kaniko/.docker/config.json`）
- [ ] 镜像 tag 格式 `${IMAGE_PREFIX}-${VERSION}`（test-1.0.1 / uat-1.0.1 / prod-1.0.1）
- [ ] master 分支 deploy 只允许 manual
- [ ] 变量 `HARBOR_PROJECT` / `MODULE` / namespace 已替换为本项目值

---

## 何时调用此 skill

- 用户说"给 React 项目写 CI" / "生成 React Dockerfile"
- 用户提到 `package.json` + `vite.config.js` + `react`
- 用户的项目目录有 `package.json` 且 dependencies 含 `react` + `vite`
- 用户说"React + Vite 怎么部署到 K8s"
- 用户说"前端项目需要 gzip 预压缩"
