# 使用官方 Node.js 镜像作为基础镜像
FROM node:16

# 设置工作目录
WORKDIR /app

# 设置 npm 镜像源为 npmmirror
RUN npm config set registry https://registry.npmmirror.com

# 将 package.json 和 package-lock.json 复制到工作目录
COPY package*.json ./

# 安装依赖
RUN npm install

# 将应用源代码复制到容器中
COPY . .

# 安装 Nginx
RUN apt-get update && \
    apt-get install -y nginx && \
    apt-get clean

# 配置 Nginx
COPY nginx.conf /etc/nginx/nginx.conf

# 暴露端口 80 和 3000
EXPOSE 80 3000

# 启动 Node.js 应用和 Nginx
CMD service nginx start && npm start
