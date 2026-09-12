---
name: ci-go
description: Use when a repository contains go.mod and the user asks for GitLab CI, a Go Dockerfile, image publishing, or Kubernetes deployment. Do not use for non-Go projects or containerd mirror setup.
---

# Go CI/CD

公共流水线、ACR、Kaniko、分支映射和 Kubernetes 发布规则必须使用 `ci-gitlab-kaniko`。

## 识别项目

适用条件：仓库有 `go.mod`，入口在根目录或 `cmd/<service>/`。先确认服务监听端口、构建入口和是否需要 CGO；不要假设所有 Go 服务都能关闭 CGO。

## Dockerfile：纯 Go 静态二进制

```dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /src
ENV GOPROXY=https://goproxy.cn,direct
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/app .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
```

节点 containerd 负责镜像加速；不要把 `FROM` 改成 Harbor 域名。需要 CA、时区或动态链接库时，改用明确版本的 Alpine/Debian runtime，并说明原因。

多模块构建示例：

```dockerfile
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o /out/service ./cmd/service
```

## Go 专属 CI 参数

交给 `ci-gitlab-kaniko` 的 `build-image` 追加必要参数即可。公共变量至少包括：

```yaml
IMAGE_NAME: service-name
GO_VERSION: "1.23"
```

不要在流水线里覆盖 `IMAGE_REGISTRY` 为 Harbor。Go 模块代理只影响依赖下载，不改变镜像地址。

## 检查清单

- [ ] `go.mod`/`go.sum` 先复制再下载依赖
- [ ] 明确 `CGO_ENABLED` 是否适用
- [ ] 运行时不包含 Go 工具链和源码
- [ ] 默认使用非 root 用户
- [ ] 基础镜像固定版本且保持上游地址
- [ ] 公共 CI 使用 ACR push 和 rollout status
- [ ] 多模块项目的 `go build` 路径与产物一致

## 何时不要用

没有 `go.mod`、只是修改 Shell/Kubernetes YAML，或问题属于节点 containerd mirror 配置时，不调用本技能。
