# 多阶段构建:alpine 编译 + alpine 运行(走 dockerhub.ihome 代理,不依赖 gcr.io)
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

# 运行层:alpine 体积 ~7MB,加 ca-certs ~9MB
# 不用 distroless 因为 gcr.io 国内不通,而 Docker registry-mirrors 只代理 docker.io
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata && \
    addgroup -S app && adduser -S app -G app
COPY --from=builder /out/node-cordon-watcher /usr/local/bin/node-cordon-watcher
USER app:app
ENTRYPOINT ["/usr/local/bin/node-cordon-watcher"]
EXPOSE 8080
