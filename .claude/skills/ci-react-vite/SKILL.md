---
name: ci-react-vite
description: Use when package.json depends on react and vite and the user asks for GitLab CI, a React Dockerfile, SPA hosting, image publishing, or Kubernetes deployment. Do not use for Vue, uni-app, or generic frontend projects without React.
---

# React + Vite CI/CD

公共流水线、ACR、Kaniko、分支映射和 Kubernetes 发布使用 `ci-gitlab-kaniko`。

## Dockerfile

```dockerfile
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
RUN npm run build \
    && find dist -type f -size +1k \( -name '*.js' -o -name '*.css' -o -name '*.html' -o -name '*.svg' -o -name '*.json' \) -exec gzip -k {} +

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
```

使用 pnpm 时必须先确认存在并提交 `pnpm-lock.yaml`，然后使用 `pnpm install --frozen-lockfile`；锁文件缺失或过期必须失败，不得自动降级到非锁定安装。所有 `FROM` 保持上游地址。

## nginx 基线

```nginx
server {
    listen 80;
    root /usr/share/nginx/html;
    location = /healthz { return 200 "ok\n"; }
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
    location / { try_files $uri $uri/ /index.html; }
}
```

仅当 Vite 输出带 hash 时使用长期缓存；API 代理和非 SPA 路由按项目实际配置。

## React 专属 CI 参数

```yaml
NODE_VERSION: "22"
BUILD_COMMAND: npm run build
MODULE: react-app
```

环境变量使用 Vite 原生 `--mode` 时，通过公共技能的显式 build arg 传递；不要把秘密编译进前端产物。

## 检查清单

- [ ] React/Vite 依赖和构建命令已核对
- [ ] lockfile 安装不可复现时直接失败
- [ ] gzip 仅处理实际存在的 `dist`
- [ ] nginx 有 SPA fallback 和 `/healthz`
- [ ] 基础镜像固定版本且保持上游地址
- [ ] 使用 `ci-gitlab-kaniko` 推送 ACR 并等待 rollout

## 何时不要用

项目没有 React，属于 Vue/uni-app/Nuxt，或只是在改 nginx/K8s 配置时，不调用本技能。
