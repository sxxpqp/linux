---
name: ci-java-maven
description: Use when a repository contains pom.xml with Maven jar packaging and the user asks for GitLab CI, a Spring Boot Dockerfile, image publishing, or Kubernetes deployment. Do not use for Gradle or non-Java projects.
---

# Java Maven CI/CD

公共流水线、ACR、Kaniko、分支映射和 Kubernetes 发布使用 `ci-gitlab-kaniko`。

## 识别项目

适用条件：存在 `pom.xml`，项目 packaging 为 `jar` 或可产出可执行 Spring Boot jar。先确认 Java 版本、模块结构、profile、端口和健康端点。

## Maven 构建

Dockerfile 只负责运行时，不在镜像构建阶段编译：

```dockerfile
FROM eclipse-temurin:17-jre-alpine
RUN addgroup -S -g 10001 app && adduser -S -D -u 10001 -G app app
WORKDIR /app
COPY target/app.jar /app/app.jar
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

多模块项目在 CI 中将最终 jar 复制到构建上下文的 `target/app.jar`。基础镜像保持上游地址，由节点 containerd mirror 处理可达性。

```bash
export MAVEN_OPTS="-Dmaven.repo.local=${CI_PROJECT_DIR}/.m2/repository"
mvn clean package -P"${MAVEN_PROFILE}" -U
```

测试默认必须运行。只有明确批准时才设置 `MAVEN_SKIP_TESTS=true`，并在流水线中显式追加 `-DskipTests`；不要把跳过测试写成默认模板。

## Maven 专属 CI 参数

```yaml
MAVEN_PROFILE: test
MAVEN_SKIP_TESTS: "false"
```

将 `.m2/repository/` 按 `CI_COMMIT_REF_SLUG` 缓存，package job 使用 `pull-push`；构建和部署 job 不写 Maven 缓存。由公共技能统一镜像变量和发布命令。

## 检查清单

- [ ] 运行时只有 JRE 和 jar
- [ ] Java 版本与项目编译版本一致
- [ ] Maven 默认运行测试
- [ ] 多模块最终 jar 路径明确
- [ ] Dockerfile `FROM` 保持上游、版本固定
- [ ] 使用 `ci-gitlab-kaniko` 推送 ACR 并等待 rollout

## 何时不要用

使用 Gradle、没有 Maven `pom.xml`，或问题属于通用 Kubernetes YAML / 节点镜像 mirror 时，不调用本技能。
