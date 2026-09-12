---
name: ci-vue-vite
description: Use when package.json depends on vue/vite or the project is uni-app or Nuxt and the user asks for GitLab CI, a frontend Dockerfile, SPA hosting, image publishing, or Kubernetes deployment. Do not use for React-only or generic frontend projects.
---

# Vue + Vite CI/CD

公共流水线、ACR、Kaniko、分支映射和 Kubernetes 发布使用 `ci-gitlab-kaniko`。

## 构建模式

先读取 `package.json` 的 `scripts.build`：

| 判断 | 做法 |
|---|---|
| `vite build` 或标准 Vite 脚本 | 使用 `npm/pnpm run build` |
| 仅通过 `.env.<mode>` 切环境 | 优先 `npm run build -- --mode "${BUILD_MODE}"` |
| 多入口、自定义产物或项目编排脚本 | 最后才使用项目已有的 `node build.js` |
| uni-app | 使用项目实际的 `build:h5` 或平台构建命令 |
| Nuxt | 按 Nuxt 的 `.output`/启动方式，不套 SPA `dist` 模板 |

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
```

`BUILD_MODE` 必须限制在项目已存在的 mode 集合内；自定义 build.js 只在标准 `--mode` 无法表达多入口/多产物时使用，并验证实际产物目录。

## 检查清单

- [ ] 已核对 Vue/Vite/uni-app/Nuxt 类型和实际构建脚本
- [ ] mode 只传入项目支持的值
- [ ] lockfile 安装失败直接终止
- [ ] SPA 产物确认存在后才进入 runtime stage
- [ ] nginx 有 `/healthz`，SPA 项目有 fallback
- [ ] 使用 `ci-gitlab-kaniko` 推送 ACR 并等待 rollout

## 何时不要用

项目只有 React，或问题属于通用 Kaniko、Kubernetes YAML、Shell 脚本和 containerd mirror 时，不调用本技能。
