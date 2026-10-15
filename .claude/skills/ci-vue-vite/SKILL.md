---
name: ci-vue-vite
description: Use when package.json depends on vue/vite or the project is uni-app or Nuxt and the user asks for GitLab CI, a frontend Dockerfile, SPA hosting, image publishing, or Kubernetes deployment. Do not use for React-only or generic frontend projects.
---

# Vue + Vite CI/CD

公共流水线、镜像仓库、Kaniko、分支映射和 Kubernetes 发布使用 `ci-gitlab-kaniko`。

## 构建模式

先读取 `package.json` 的 `scripts.build`：

| 判断 | 做法 |
|---|---|
| `vite build` 或标准 Vite 脚本 | 使用 `npm/pnpm run build` |
| 仅通过 `.env.<mode>` 切环境 | 优先 `npm run build -- --mode "${BUILD_MODE}"` |
| 多入口、自定义产物或项目编排脚本 | 最后才使用项目已有的 `node build.js` |
| uni-app | 使用项目实际的 `build:h5` 或平台构建命令 |
| Nuxt | 按 Nuxt 的 `.output`/启动方式，不套 SPA `dist` 模板 |

判断原则：**能用 `--mode` 就不要上 `node build.js`**。`--mode` 是 Vite 原生环境加载机制，可移植、可缓存；`build.js` 是项目私有编排，只在多入口/非标准产物时才需要。

### 环境变量注入 → `--mode`（优先）

标准 Vite 工程只是用 `.env.staging` / `.env.pre` / `.env.production` 切环境，CI 只传一个 `--build-arg BUILD_MODE`，Dockerfile 里 `case` 映射成具体 mode：

```dockerfile
ARG BUILD_MODE=production
ARG NODE_MAX_OLD_SPACE_SIZE=8192
ENV NODE_OPTIONS="--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE}"
RUN case "${BUILD_MODE}" in \
      staging)    VITE_MODE=staging ;;
      pre)        VITE_MODE=pre ;;
      production) VITE_MODE=production ;;
      *) echo "Unsupported BUILD_MODE: ${BUILD_MODE}" && exit 1 ;;
    esac \
 && npm run build -- --mode ${VITE_MODE} \
 && test -d dist
```

三个容易漏的点：

- **`NODE_MAX_OLD_SPACE_SIZE`**：大项目(页面/组件多)Vite 构建容易 `JavaScript heap out of memory`。默认给 8192，CI 变量 `NODE_MAX_OLD_SPACE_SIZE` 透传 build-arg。
- **`test -d dist` 产物目录守卫**：`.env.<mode>` 里的 `VITE_APP_outputDir` 可能把产物目录改成 `dist/web` 之类，导致 runtime stage `COPY --from=build /app/dist` 落空。守卫住，失败要早。
- **私有 npm 源**：`.npmrc` 必须跟 `package.json` / lockfile 一起 COPY，否则 `@scope/*` 私有包装不上。

项目自带命名脚本(`npm run stage` / `build:pre` / `build:prod`，本质仍是 `vite build --mode`)时，`case` 直接映射到脚本名即可，参考 `D:\code\game-combine-h5\game-lottery-h5\Dockerfile`。

### 自定义 build.js（最后手段）

来源 `xet-live-h5`：项目自带 `node build.js` 编排构建，`BUILD_TYPE` 选入口(web/app)、`VITE_MODE` 选环境，产物是 `dist/web` / `dist/app` 而非 `dist`：

```dockerfile
RUN BUILD_TYPE=web BUILD_TAG="${BUILD_TAG}" VITE_MODE="${VITE_MODE}" node build.js \
    && test -d dist/web
```

runtime stage 的 `COPY --from=build /app/dist/web` 和 gzip 的 `find` 路径都要跟着改成 `dist/web`。

## Dockerfile：标准 Vite SPA

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
ARG BUILD_MODE=production
RUN npm run build -- --mode "${BUILD_MODE}" \
    && test -d dist \
    && find dist -type f -size +1k \( -name '*.js' -o -name '*.css' -o -name '*.html' -o -name '*.svg' -o -name '*.json' \) -exec gzip -k {} +

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

pnpm 项目必须使用已提交的 lockfile 和 `pnpm install --frozen-lockfile`，不允许锁文件失败后自动 `pnpm install`。私有 npm 源配置使用 CI Secret，不要把 token 写进 `.npmrc` 或镜像层。`FROM` 保持上游地址。

## nginx 基线

```nginx
server {
    listen 80;
    root /usr/share/nginx/html;
    location = /healthz { return 200 "ok\n"; }
    location / { try_files $uri $uri/ /index.html; }
}
```

## Vue 专属 CI 参数

```yaml
NODE_VERSION: "22"
BUILD_MODE: production
MODULE: vue-app
NODE_MAX_OLD_SPACE_SIZE: "8192"
```

`BUILD_MODE` 必须限制在项目已存在的 mode 集合内；自定义 build.js 只在标准 `--mode` 无法表达多入口/多产物时使用，并验证实际产物目录。`NODE_MAX_OLD_SPACE_SIZE` 由 kaniko 用 `--build-arg` 透传。

## 检查清单

- [ ] 已核对 Vue/Vite/uni-app/Nuxt 类型和实际构建脚本
- [ ] mode 只传入项目支持的值
- [ ] lockfile 安装失败直接终止
- [ ] SPA 产物确认存在后才进入 runtime stage
- [ ] nginx 有 `/healthz`，SPA 项目有 fallback
- [ ] 使用 `ci-gitlab-kaniko` 推送镜像并等待 rollout
- [ ] 大项目已配 `NODE_MAX_OLD_SPACE_SIZE` 并透传 build-arg
- [ ] 构建后有 `test -d <产物目录>` 守卫，目录与 runtime stage 的 `COPY` 路径一致

## 何时不要用

项目只有 React，或问题属于通用 Kaniko、Kubernetes YAML、Shell 脚本和 containerd mirror 时，不调用本技能。
