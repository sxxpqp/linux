---
name: ci-go
description: "Go 项目 GitLab CI/CD + Dockerfile 生产模板。多阶段构建(Kaniko)→ alpine/distroless 运行时，含 GOPROXY 加速、静态编译、非 root 用户、K8s 滚动部署。触发词: go ci, golang ci, go dockerfile, 后端 ci, 写 Go 流水线, 生成 Go dockerfile, go build, golang build"
---

# Go 项目 CI/CD 生产模板

> 提取自 `D:\code\tracking-gateway`、`D:\code\user-gateway`、`D:\code\tracking-collector` 等 11 个真实项目。
> CI 参数风格参考 `D:\code\ad-rtb\.gitlab-ci.yml`（分支感知环境映射）。

## 核心思路

1. **多阶段构建**: builder 阶段编译静态二进制 → runtime 阶段只拷贝二进制到 alpine/distroless
2. **层缓存优化**: 先 COPY go.mod/go.sum → go mod download → 再 COPY 源码，依赖不变时命中缓存
3. **GOPROXY 加速**: `https://goproxy.cn,direct` 国内拉取 Go 模块
4. **静态编译**: `CGO_ENABLED=0 -trimpath -ldflags="-s -w"` 最小化二进制体积
5. **非 root 运行**: runtime 镜像创建 `app` 用户(UID 10001)，`USER 10001:10001`
6. **Kaniko 构建**: 无 Docker daemon，rootless，`--cache=true --cache-repo` 推送到 Harbor
7. **分支感知环境映射**: test → test namespace, release* → uat namespace, master → prod namespace(手动部署)

---

## Dockerfile 模板

```dockerfile
# ---------- Build Stage ----------
FROM hub.wishfoxs.com:6443/middleware/golang:1.23-alpine AS builder

WORKDIR /src

# 1. 先设置 GOPROXY，利用层缓存
RUN go env -w GOPROXY=https://goproxy.cn,direct

# 2. 先拷贝依赖声明，下载模块
COPY go.mod go.sum ./
RUN go mod download

# 3. 拷贝源码 + 静态编译
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/app .

# ---------- Runtime Stage ----------
FROM hub.wishfoxs.com:6443/middleware/golang:1.23-alpine

# 创建非 root 用户
RUN addgroup -g 10001 -S app && adduser -u 10001 -S app -G app

WORKDIR /app
COPY --from=builder /out/app /app/app

# 切换到非 root 用户
USER 10001:10001

EXPOSE 8080
ENTRYPOINT ["/app/app"]
```

### 变体: 多模块项目(有 cmd/ 目录)

```dockerfile
# 如果有多个二进制要编译
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" -o /out/service-a ./cmd/service-a && \
    go build -trimpath -ldflags="-s -w" -o /out/service-b ./cmd/service-b

# Runtime stage
COPY --from=builder /out/service-a /app/service-a
COPY --from=builder /out/service-b /app/service-b
```

### 变体: distroless 运行时(更安全)

```dockerfile
# Runtime Stage 换成 distroless
FROM hub.wishfoxs.com:6443/middleware/distroless/static-debian12:nonroot

COPY --from=builder /out/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
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
  HARBOR_PROJECT: "bigdata"                      # ← 改成本项目的 Harbor 命名空间
  IMAGE_NAME: "tracking-gateway"                 # ← 改成镜像名
  VERSION:
    value: "1.0.0"
    description: "镜像版本号，例如: 1.0.1（最终 tag 形如 test-1.0.1 / uat-1.0.1 / prod-1.0.1）"
  DEPLOY_TO_K8S:
    value: "true"
    description: "构建完成后是否自动滚动更新 K8s（true/false）"
  K8S_DEPLOYMENT:
    value: "tracking-gateway"                    # ← 改成 K8s Deployment 名
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

---

## 反模式表

| ✗ 错误做法 | ✓ 正确做法 | 原因 |
|---|---|---|
| `FROM golang:latest` | `FROM hub.wishfoxs.com:6443/middleware/golang:1.23-alpine` | 走 Harbor mirror，固定版本 |
| 单阶段构建，运行时镜像带 Go 工具链 + 源码 | 多阶段构建，运行时只留二进制 | 镜像体积 1GB → 15MB |
| `COPY . .` 在 `go mod download` 前 | 先 `COPY go.mod go.sum` → download → 再 `COPY .` | 层缓存失效，每次全量 download |
| `go build` 不带 `-trimpath -ldflags="-s -w"` | 静态编译 + 去调试符号 | 二进制体积减小 30-50% |
| `go mod download` 不走代理 | `go env -w GOPROXY=https://goproxy.cn,direct` | 国内直连 proxy.golang.org 不通 |
| 运行时用 root 用户 | `USER 10001:10001` 或 `USER nonroot:nonroot` | 安全最佳实践，防止容器逃逸 |
| `kubectl apply -f deployment.yaml` | `kubectl set image` + `rollout restart` | 幂等，不依赖 yaml 文件 |
| push 自动触发 CI | `workflow: rules: [web, api, trigger]` | 避免无效构建，手动控制发布节奏 |
| 镜像 tag 不带环境前缀 | `IMAGE_TAG="${IMAGE_PREFIX}-${VERSION}"` | 多环境部署时无法区分 test/uat/prod |
| master 分支自动部署 | `if: '$CI_COMMIT_REF_NAME != "master"'` + manual | 生产环境必须手动确认 |

---

## 检查清单(生成前自查)

- [ ] Dockerfile 基础镜像走 `hub.wishfoxs.com:6443/middleware/...`
- [ ] 多阶段构建，运行时只留二进制
- [ ] 层缓存优化：先 COPY go.mod/go.sum → download → 再 COPY 源码
- [ ] `GOPROXY=https://goproxy.cn,direct` 设置正确
- [ ] 静态编译：`CGO_ENABLED=0 -trimpath -ldflags="-s -w"`
- [ ] 非 root 用户运行（`USER 10001:10001` 或 `nonroot`）
- [ ] .gitlab-ci.yml 有 `workflow: rules` 限制手动触发
- [ ] .gitlab-ci.yml 有 `before_script` 分支感知环境映射（case 语句）
- [ ] .gitlab-ci.yml Kaniko auth 正确（`/kaniko/.docker/config.json`）
- [ ] .gitlab-ci.yml 有 `--cache=true --cache-repo`
- [ ] 镜像 tag 格式 `${IMAGE_PREFIX}-${VERSION}`（test-1.0.1 / uat-1.0.1 / prod-1.0.1）
- [ ] master 分支 deploy 只允许 manual
- [ ] 变量 `HARBOR_PROJECT` / `IMAGE_NAME` / `K8S_DEPLOYMENT` / namespace 已替换为本项目值

---

## 何时调用此 skill

- 用户说"给 Go 项目写 CI" / "生成 Go Dockerfile"
- 用户提到 `go.mod` + `main.go` / `cmd/`
- 用户的项目目录有 `go.mod` 且 module 名非空
- 用户说"Go 服务怎么构建镜像" / "Golang 怎么部署到 K8s"
