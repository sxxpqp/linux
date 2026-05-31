# 使用官方 Nginx 基础镜像
FROM nginx:latest

# 设置时区为 Asia/Shanghai
ENV TZ=Asia/Shanghai

# 将自定义的 default.conf 复制到容器的配置目录
COPY default.conf /etc/nginx/conf.d/default.conf

# 暴露 HTTP 和 HTTPS 端口
EXPOSE 80 443

# 启动 Nginx 服务
CMD ["nginx", "-g", "daemon off;"]
