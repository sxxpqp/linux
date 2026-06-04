# 多阶段构建:alpine 编译,distroless 运行
# 构建产物:registry.cn-hangzhou.aliyuncs.com/sxxpqp/node-cordon-watcher

FROM golang:1.22-alpine AS builder
WORKDIR /src

# 国内 goproxy(CLAUDE.md 已记录)
ENV GOPROXY=https://goproxy.cn,direct \
    GOSUMDB=off \
    CGO_ENABLED=0 \
    GOOS=linux

# 先拷 go.mod 单独下依赖(利用 layer cache)
COPY go.mod go.sum* ./
RUN go mod download

COPY . .
RUN go build -trimpath -ldflags="-s -w" -o /out/node-cordon-watcher .

# 运行层:distroless,无 shell、无包管理器,最小攻击面
FROM gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=builder /out/node-cordon-watcher /node-cordon-watcher
USER nonroot:nonroot
ENTRYPOINT ["/node-cordon-watcher"]
EXPOSE 8080
