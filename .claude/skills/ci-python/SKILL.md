---
name: ci-python
description: Use when a repository contains requirements.txt or pyproject.toml with FastAPI/Uvicorn and the user asks for GitLab CI, a Python Dockerfile, image publishing, or Kubernetes deployment. Do not use for non-Python projects.
---

# Python CI/CD

公共流水线、ACR、Kaniko、分支映射和 Kubernetes 发布使用 `ci-gitlab-kaniko`。

## 识别项目

先确认依赖文件、ASGI 应用导入路径、监听端口、系统依赖和健康端点。下面以 `app.main:app` 为例，不要把它当成所有项目的固定入口。

## Dockerfile：可编译依赖

```dockerfile
FROM python:3.13-slim AS build
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends build-essential gcc libssl-dev \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.13-slim
RUN useradd --create-home --uid 10001 app
WORKDIR /app
COPY --from=build /install /usr/local
COPY app ./app
RUN chown -R 10001:10001 /app
USER 10001:10001
EXPOSE 80
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "80"]
```

需要 ffmpeg 等系统包时，在最终镜像安装明确版本并清理 apt cache；只在确实需要时加入，不要把业务无关依赖放进通用模板。pip 源可通过构建环境配置覆盖，不要把私有凭据写入 Dockerfile。

## Python 专属 CI 参数

```yaml
PYTHON_VERSION: "3.13"
MODULE: service-name
```

依赖安装必须先复制 lock/requirements 文件再复制源码。公共技能负责 ACR push、受保护的 kubeconfig、环境映射和 rollout status。

## 检查清单

- [ ] 应用监听 `0.0.0.0`，端口和 Service 一致
- [ ] 依赖层先构建，最终镜像不包含编译工具（除非明确需要）
- [ ] 默认非 root UID 10001
- [ ] 使用固定版本基础镜像
- [ ] 私有源凭据不进入镜像和日志
- [ ] 使用 `ci-gitlab-kaniko` 发布 ACR/Kubernetes

## 何时不要用

不是 Python/FastAPI 项目，或只是修改 K8s YAML、Shell 脚本、containerd mirror 时，不调用本技能。
