---
name: ci-java-maven
description: "Java Maven 项目 GitLab CI/CD + Dockerfile 生产模板。多阶段构建(Maven package → Kaniko)→ JRE 运行时，含 Maven 缓存、分支感知环境映射、K8s 滚动部署。触发词: java ci, maven ci, spring boot ci, java dockerfile, 后端 ci, 写 Java 流水线, 生成 Java dockerfile, mvn package, spring boot 部署"
---

# Java Maven 项目 CI/CD 生产模板

> 提取自 `D:\code\ad-rtb`、`D:\code\user-center`、`D:\code\gateway` 等 8 个真实项目。
> CI 参数风格参考 `D:\code\ad-rtb\.gitlab-ci.yml`（分支感知环境映射 + Maven profile 映射）。

## 核心思路

1. **3 阶段流水线**: package(Maven 编译) → build_image(Kaniko 打镜像) → deploy(K8s 滚动更新)
2. **Maven 缓存**: `.m2/repository/` 按 `CI_COMMIT_REF_SLUG` 分 key，pull-push 策略
3. **分支感知环境映射**: `before_script` 中 `case CI_COMMIT_REF_NAME` 映射 `test → test/dsp-test`, `release* → uat/dsp-uat`, `master → prod/dsp-prod`
4. **Maven profile 联动**: 分支同时决定 `MAVEN_PROFILE`(test/prod) 和 `IMAGE_PREFIX`(test/uat/prod)
5. **镜像 tag 约定**: `${IMAGE_PREFIX}-${VERSION}`（如 test-1.0.1 / uat-1.0.1 / prod-1.0.1）
6. **master 手动部署**: deploy 阶段 master 分支只允许 manual，非 master + DEPLOY_TO_K8S=true 自动部署
7. **Kaniko 构建**: Dockerfile 内只做 COPY jar + 装 JRE，不编译

---

## Dockerfile 模板

```dockerfile
# ---------- Runtime Stage ----------
FROM hub.wishfoxs.com:6443/middleware/eclipse-temurin:11-jre-alpine

# 创建非 root 用户
RUN addgroup -g 10001 -S app && adduser -u 10001 -S app -G app

WORKDIR /app

# Kaniko 构建时 artifact 会 COPY 进来
COPY target/app.jar /app/app.jar

# 时区设置
ENV TZ=Asia/Shanghai
RUN apk add --no-cache tzdata \
    && cp /usr/share/zoneinfo/$TZ /etc/localtime \
    && echo $TZ > /etc/timezone

USER 10001:10001

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

### 变体: JDK 17

```dockerfile
FROM hub.wishfoxs.com:6443/middleware/eclipse-temurin:17-jre-alpine
```

### 变体: 多模块项目(jar 在子模块 target 下)

```dockerfile
# 假设 jar 在 xxx-start/target/app.jar
COPY xxx-start/target/app.jar /app/app.jar
```

### 变体: 需要 JVM 参数

```dockerfile
ENTRYPOINT ["java", "-Xms256m", "-Xmx512m", "-XX:+UseG1GC", "-jar", "/app/app.jar"]
```

---

## .gitlab-ci.yml 模板

```yaml
# 仅允许在 GitLab 页面/API/trigger 手动触发流水线；非 master 分支可按 DEPLOY_TO_K8S 自动部署，master 仅手动部署
workflow:
  rules:
    - if: '$CI_PIPELINE_SOURCE == "web"'
    - if: '$CI_PIPELINE_SOURCE == "api"'
    - if: '$CI_PIPELINE_SOURCE == "trigger"'

default:
  tags:
    - docker
  before_script:
    - export MAVEN_OPTS="-Dmaven.repo.local=${CI_PROJECT_DIR}/.m2/repository"
    - |
      case "${CI_COMMIT_REF_NAME}" in
        test)
          MAVEN_PROFILE="test"
          IMAGE_PREFIX="test"
          K8S_NAMESPACE="xxx-test"           # ← 改成实际 namespace
          ;;
        release|release-*)
          MAVEN_PROFILE="prod"
          IMAGE_PREFIX="uat"
          K8S_NAMESPACE="xxx-uat"            # ← 改成实际 namespace
          ;;
        master)
          MAVEN_PROFILE="prod"
          IMAGE_PREFIX="prod"
          K8S_NAMESPACE="xxx"                # ← 改成实际 namespace
          ;;
        *)
          echo "ERROR: 当前分支 ${CI_COMMIT_REF_NAME} 未配置流水线环境"
          exit 1
          ;;
      esac

      export MAVEN_PROFILE
      export K8S_NAMESPACE
      export IMAGE_TAG="${IMAGE_PREFIX}-${VERSION}"

stages:
  - package
  - build_image
  - deploy

variables:
  MAVEN_IMAGE: "hub.wishfoxs.com:6443/middleware/maven:3.8.6-openjdk-11"
  KANIKO_IMAGE: "hub.wishfoxs.com:6443/middleware/executor:debug"
  KUBECTL_IMAGE: "hub.wishfoxs.com:6443/middleware/kubectl:latest"
  HARBOR_REGISTRY: "hub.wishfoxs.com:6443"
  HARBOR_PROJECT: "ad"                           # ← 改成本项目的 Harbor 命名空间
  IMAGE_NAME: "ad-rtb"                           # ← 改成镜像名
  VERSION:
    value: "1.0.0"
    description: "镜像版本号，例如: 1.0.1（最终 tag 形如 test-1.0.1 / uat-1.0.1 / prod-1.0.1）"
  DEPLOY_TO_K8S:
    value: "true"
    description: "构建完成后是否自动滚动更新 K8s（true/false）"
  K8S_DEPLOYMENT:
    value: "ad-rtb"                              # ← 改成 K8s Deployment 名
    description: "K8s 中的 Deployment 名称"

cache:
  key: "maven-${CI_COMMIT_REF_SLUG}"
  paths:
    - .m2/repository/

# ============================================================
# Stage 1: Maven 打包
# ============================================================
package:
  stage: package
  image: $MAVEN_IMAGE
  cache:
    key: "maven-${CI_COMMIT_REF_SLUG}"
    paths:
      - .m2/repository/
    policy: pull-push
  script:
    - |
      echo "===== Maven 打包: ${IMAGE_NAME} ====="
      echo "branch=${CI_COMMIT_REF_NAME}"
      echo "profile=${MAVEN_PROFILE}"
      mvn clean package -P${MAVEN_PROFILE} -DskipTests -U
      ls -lh */target/*.jar
  artifacts:
    expire_in: 1 hour
    paths:
      - "*/target/*.jar"

# ============================================================
# Stage 2: Kaniko 构建镜像
# ============================================================
build-image:
  stage: build_image
  image:
    name: $KANIKO_IMAGE
    entrypoint: [""]
  needs:
    - job: package
      artifacts: true
  cache: []
  script:
    - mkdir -p /kaniko/.docker
    - |
      cat > /kaniko/.docker/config.json <<EOF
      {"auths":{"${HARBOR_REGISTRY}":{"username":"${HARBOR_USERNAME}","password":"${HARBOR_PASSWORD}"}}}
      EOF
    - |
      # 找到 jar 文件(适配多模块项目)
      JAR=$(find ${CI_PROJECT_DIR} -path "*/target/*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" | head -1)
      if [ -z "$JAR" ]; then
        echo "ERROR: 未找到 jar 文件"
        exit 1
      fi
      echo "===== 找到 jar: $JAR ====="

      # 拷贝 jar 到 target 目录供 Dockerfile COPY
      mkdir -p ${CI_PROJECT_DIR}/target
      cp "$JAR" ${CI_PROJECT_DIR}/target/app.jar

      echo "===== Kaniko 构建: ${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG} ====="
      /kaniko/executor \
        --context "${CI_PROJECT_DIR}" \
        --dockerfile "${CI_PROJECT_DIR}/Dockerfile" \
        --destination "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG}" \
        --cache=true \
        --verbosity=info

# ============================================================
# Stage 3: 滚动更新 K8s 服务
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
| `FROM openjdk:11` | `FROM hub.wishfoxs.com:6443/middleware/eclipse-temurin:11-jre-alpine` | 走 Harbor mirror，用 JRE 不用 JDK，alpine 更小 |
| Dockerfile 里 `mvn package` | Maven 打包在 CI stage 完成，Dockerfile 只 COPY jar | Docker 构建环境不可控，Maven 缓存无法复用 |
| 没设 `MAVEN_OPTS` | `export MAVEN_OPTS="-Dmaven.repo.local=${CI_PROJECT_DIR}/.m2/repository"` | 指定本地仓库路径，cache 才能命中 |
| cache 没设 `policy: pull-push` | package 阶段 `policy: pull-push`，其他阶段 `cache: []` | 只有 package 需要写缓存，其他阶段只读或不读 |
| 没设 `MAVEN_PROFILE` | 分支映射同时决定 profile 和 image prefix | test 分支用 test profile，release/master 用 prod profile |
| `kubectl apply -f deployment.yaml` | `kubectl set image` + `rollout restart` | 幂等，不依赖 yaml 文件 |
| push 自动触发 CI | `workflow: rules: [web, api, trigger]` | 避免无效构建，手动控制发布节奏 |
| 镜像 tag 不带环境前缀 | `IMAGE_TAG="${IMAGE_PREFIX}-${VERSION}"` | 多环境部署时无法区分 test/uat/prod |
| master 分支自动部署 | `if: '$CI_COMMIT_REF_NAME != "master"'` + manual | 生产环境必须手动确认 |
| artifacts 不设过期时间 | `expire_in: 1 hour` | jar 只在下个 stage 用，不需要长期保存 |

---

## 检查清单(生成前自查)

- [ ] Dockerfile 基础镜像走 `hub.wishfoxs.com:6443/middleware/...`
- [ ] Dockerfile 只 COPY jar，不编译
- [ ] 非 root 用户运行（`USER 10001:10001`）
- [ ] 时区设置 `Asia/Shanghai`
- [ ] 3 阶段流水线：package → build_image → deploy
- [ ] `MAVEN_OPTS` 指定本地仓库路径
- [ ] Maven cache `key: "maven-${CI_COMMIT_REF_SLUG}"`，package 阶段 `policy: pull-push`
- [ ] .gitlab-ci.yml 有 `workflow: rules` 限制手动触发
- [ ] .gitlab-ci.yml 有 `before_script` 分支感知环境映射（case 语句）
- [ ] 分支映射同时决定 `MAVEN_PROFILE` / `IMAGE_PREFIX` / `K8S_NAMESPACE`
- [ ] .gitlab-ci.yml Kaniko auth 正确（`/kaniko/.docker/config.json`）
- [ ] .gitlab-ci.yml 有 `--cache=true`
- [ ] 镜像 tag 格式 `${IMAGE_PREFIX}-${VERSION}`（test-1.0.1 / uat-1.0.1 / prod-1.0.1）
- [ ] master 分支 deploy 只允许 manual
- [ ] artifacts `expire_in: 1 hour`
- [ ] 变量 `HARBOR_PROJECT` / `IMAGE_NAME` / `K8S_DEPLOYMENT` / namespace 已替换为本项目值

---

## 何时调用此 skill

- 用户说"给 Java 项目写 CI" / "生成 Spring Boot Dockerfile"
- 用户提到 `pom.xml` + `mvn` / `maven`
- 用户的项目目录有 `pom.xml` 且 packaging 为 jar
- 用户说"Java 服务怎么构建镜像" / "Spring Boot 怎么部署到 K8s"
- 用户说"多模块 Maven 项目怎么配流水线"
