---
name: ci-python
description: "Python 项目 GitLab CI/CD + Dockerfile 生产模板。FastAPI + Uvicorn 异步框架，多阶段构建(Kaniko)，含 pip 镜像加速、依赖层缓存、K8s 滚动部署。触发词: python ci, fastapi ci, python dockerfile, 后端 ci, 写 Python 流水线, 生成 Python dockerfile, pip install, uvicorn 部署, fastapi 部署"
---

# Python 项目 CI/CD 生产模板

> 提取自 `D:\code\ai-ad-gen`、`D:\code\wishes_abroad` 等真实项目。
> CI 参数风格参考 `D:\code\ad-rtb\.gitlab-ci.yml`（分支感知环境映射）。

## 核心思路

1. **FastAPI + Uvicorn**: 异步框架，容器内监听 `0.0.0.0:80`，开发环境 `8001`
2. **层缓存优化**: 先 COPY `requirements.txt` → `pip install` → 再 COPY 源码，lockfile 不变时命中缓存
3. **pip 镜像加速**: 阿里云 PyPI 源 (`mirrors.aliyun.com/pypi/simple/`)
4. **apt 镜像加速**: 清华源替换 Debian 默认源
5. **系统依赖**: `build-essential` + `ffmpeg`（音视频处理常用）
6. **分支感知环境映射**: test → test namespace, release* → uat namespace, master → prod namespace(手动部署)
7. **Kaniko 构建**: 无 Docker daemon，rootless，`--cache=true --cache-repo` 推送到 Harbor

---

## Dockerfile 模板

### 单阶段构建（推荐，适合大多数 FastAPI 项目）

```dockerfile
FROM hub.wishfoxs.com:6443/middleware/python:3.13

WORKDIR /app

# apt 源替换为清华镜像
RUN if [ -f /etc/apt/sources.list ]; then \
        sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g; s|security.debian.org|mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list; \
    fi

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    build-essential gcc libssl-dev ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# pip 配置阿里云镜像
RUN pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/ && \
    pip config set global.trusted-host mirrors.aliyun.com

# 层缓存优化：先拷贝依赖声明
COPY requirements.txt .
RUN pip install --upgrade pip
RUN pip install --no-cache-dir -r requirements.txt

# 拷贝源码
COPY ./app ./app/

EXPOSE 80
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "80"]
```

### 多阶段构建（适合需要编译依赖的项目）

```dockerfile
# ---- 阶段 1: 构建器 ----
FROM python:3.12-bullseye as builder
RUN apt-get update && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix="/install" -r requirements.txt

# ---- 阶段 2: 最终镜像 ----
FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /install /usr/local
COPY ./app ./app/
EXPOSE 80
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "80"]
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
  HARBOR_PROJECT: "wishfox-ai"                   # ← 改成本项目的 Harbor 命名空间
  MODULE: "ai-ad-gen-server"                     # ← 改成镜像名 / Deployment 名
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
  name: ai-ad-gen-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ai-ad-gen-server
  template:
    metadata:
      labels:
        app: ai-ad-gen-server
    spec:
      containers:
        - name: ai-ad-gen-server
          image: hub.wishfoxs.com:6443/wishfox-ai/ai-ad-gen-server:test-1.0.0
          ports:
            - containerPort: 80
          livenessProbe:
            httpGet:
              path: /health
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: 1000m
              memory: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: ai-ad-gen-server
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 80
  selector:
    app: ai-ad-gen-server
```

---

## 反模式表

| ✗ 错误做法 | ✓ 正确做法 | 原因 |
|---|---|---|
| `pip install` 不走镜像 | `pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/` | 国内直连 PyPI 极慢，构建超时 |
| `apt` 不走镜像 | `sed -i 's|deb.debian.org|mirrors.tuna.tsinghua.edu.cn|g'` | Debian 默认源国内慢 |
| `COPY . .` 后再 install | 先 `COPY requirements.txt` → install → 再 `COPY` 源码 | 源码改动时不重新 install，层缓存命中 |
| `python:3.12` 公共镜像 | `hub.wishfoxs.com:6443/middleware/python:3.13` | 走 Harbor 镜像加速，避免 Docker Hub 拉取失败 |
| 开发端口 8001 写死 | 容器内 EXPOSE 80，开发环境 8001 | 容器内统一 80，K8s Service 映射简单 |
| `python app.py` 启动 | `uvicorn app.main:app --host 0.0.0.0 --port 80` | FastAPI 必须用 ASGI server，uvicorn 是官方推荐 |
| `pip install -r requirements.txt` 带缓存 | `pip install --no-cache-dir` | 镜像体积膨胀，Docker 层已缓存 |
| push 自动触发 CI | `workflow: rules: [web, api, trigger]` | 避免无效构建，手动控制发布节奏 |
| 镜像 tag 不带环境前缀 | `IMAGE_TAG="${IMAGE_PREFIX}-${VERSION}"` | 多环境部署时无法区分 test/uat/prod |
| master 分支自动部署 | `if: '$CI_COMMIT_REF_NAME != "master"'` + manual | 生产环境必须手动确认 |

---

## 检查清单(生成前自查)

- [ ] Dockerfile 基础镜像走 `hub.wishfoxs.com:6443/middleware/python:3.13`
- [ ] apt 源替换为清华镜像 (`mirrors.tuna.tsinghua.edu.cn`)
- [ ] pip 源替换为阿里云镜像 (`mirrors.aliyun.com/pypi/simple/`)
- [ ] 层缓存优化：先 `COPY requirements.txt` → `pip install` → 再 `COPY` 源码
- [ ] `pip install --no-cache-dir` 避免镜像膨胀
- [ ] 容器内 EXPOSE 80（非 8001）
- [ ] 启动命令 `uvicorn app.main:app --host 0.0.0.0 --port 80`
- [ ] 系统依赖包含 `build-essential` + `ffmpeg`（按需）
- [ ] .gitlab-ci.yml 有 `workflow: rules` 限制手动触发
- [ ] .gitlab-ci.yml 有 `before_script` 分支感知环境映射（case 语句）
- [ ] 分支映射同时决定 `IMAGE_PREFIX` / `K8S_NAMESPACE`
- [ ] .gitlab-ci.yml Kaniko auth 正确（`/kaniko/.docker/config.json`）
- [ ] 镜像 tag 格式 `${IMAGE_PREFIX}-${VERSION}`（test-1.0.1 / uat-1.0.1 / prod-1.0.1）
- [ ] master 分支 deploy 只允许 manual
- [ ] 变量 `HARBOR_PROJECT` / `MODULE` / namespace 已替换为本项目值

---

## 何时调用此 skill

- 用户说"给 Python 项目写 CI" / "生成 FastAPI Dockerfile"
- 用户提到 `requirements.txt` + `main.py` + `FastAPI`
- 用户的项目目录有 `requirements.txt` 且含 `fastapi` / `uvicorn`
- 用户说"FastAPI / Uvicorn 怎么部署到 K8s"
- 用户说"Python 项目需要 pip 镜像加速"
