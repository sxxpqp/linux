# 使用官方 OpenJDK 17 的基础镜像
FROM openjdk:17-jdk-slim

# 设置工作目录
WORKDIR /app

# 复制应用程序的 JAR 文件到容器中
COPY target/app.jar /app/app.jar

# 暴露应用程序端口（根据应用程序配置）
EXPOSE 8080

# 启动 Java 应用程序
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
