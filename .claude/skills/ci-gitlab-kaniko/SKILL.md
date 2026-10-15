---
name: ci-gitlab-kaniko
description: Use when a project needs a GitLab CI pipeline that builds an image with Kaniko, pushes it to the customer's Harbor registry (or Aliyun ACR for this repo's own tooling images), and optionally deploys it to Kubernetes. Do not use for containerd mirror setup or language-specific build instructions.
---

# GitLab + Kaniko CI 基线

语言技能只负责项目检测、依赖安装和产物构建；流水线公共部分统一按本技能执行。

## 适用范围

GitLab CI 在本仓库只有 `devops/gitlab-ci/dsp/` 一个真实案例(✅ 生产,多模块 Java)。主力流水线是 **Jenkins on K8s(KubeSphere)**,见 `devops/jenkins.yaml` 和 `devops/{java,nodejs}/jenkinsfile` —— 用户要的是 Jenkins 就走那套,不要套本技能。

## 镜像边界

- Dockerfile `FROM` 和 K8s 第三方 `image:` 保持上游地址,例如 `docker.io/library/nginx:1.27-alpine`、`gcr.io/distroless/static-debian12:nonroot`。
- 节点通过 containerd mirror 加速。**不要**把上游 image 改写成 Harbor pull-through 域名(`dockerhub.ihome.sxxpqp.top:8443` 之类),也不要 `sed` 改 image —— 拉不到是节点 containerd 没配 mirror,不是改写 image。

### 构建产物推到哪个仓库(动手前先确认)

| 场景 | 推送目标 | 变量 |
|---|---|---|
| **客户业务镜像(默认)** | 客户自己的 Harbor | `IMAGE_REGISTRY=harbor.example.com:6443` / `IMAGE_NAMESPACE=<project>` |
| 本仓库自建运维工具镜像(kube-vip / mysql / nps 等) | 阿里 ACR,命名空间 `sxxpqp` | `IMAGE_REGISTRY=registry.cn-hangzhou.aliyuncs.com` / `IMAGE_NAMESPACE=sxxpqp` |

客户业务线以 Harbor 为主:`devops/gitlab-ci/dsp/.gitlab-ci.yml`(✅ 生产)用 `HARBOR_REGISTRY` + `HARBOR_PROJECT`,`devops/java/jenkinsfile` 用 `$REGISTRY/$DOCKERHUB_NAMESPACE`。**新项目不确定就问用户**,不要默认 ACR。

```yaml
variables:
  IMAGE_REGISTRY: harbor.example.com:6443   # 自建运维工具改 registry.cn-hangzhou.aliyuncs.com
  IMAGE_NAMESPACE: myproject                # 自建运维工具改 sxxpqp
  IMAGE_NAME: change-me
  IMAGE_TAG: "${CI_COMMIT_REF_SLUG}-${CI_PIPELINE_IID}"
```

凭据用 GitLab masked + protected variables(`HARBOR_USERNAME`/`HARBOR_PASSWORD` 或 `ACR_USERNAME`/`ACR_PASSWORD`),不写入仓库、日志或 Dockerfile。

> `infra-url-rewrite` 里说"Harbor 不接受 push",指的是**本仓库自己的 `dockerhub.ihome.sxxpqp.top:8443` 那套 pull-through 代理**。客户业务的 Harbor(如 `hub.wishfoxs.com:6443`)是独立私有仓库,**可以 push**,两者不是一回事。

## Pipeline 基线

仅允许显式触发，避免普通 push 意外构建或发布：

```yaml
workflow:
  rules:
    - if: '$CI_PIPELINE_SOURCE == "web"'
    - if: '$CI_PIPELINE_SOURCE == "api"'
    - if: '$CI_PIPELINE_SOURCE == "trigger"'
```

用项目实际分支映射环境，不要猜测 namespace：

```bash
case "${CI_COMMIT_REF_NAME}" in
test)     IMAGE_PREFIX=test; K8S_NAMESPACE=change-me-test ;;
release|release-*) IMAGE_PREFIX=uat; K8S_NAMESPACE=change-me-uat ;;
master)   IMAGE_PREFIX=prod; K8S_NAMESPACE=change-me ;;
*) echo "ERROR: branch is not mapped: ${CI_COMMIT_REF_NAME}"; exit 1 ;;
esac
export IMAGE_TAG="${IMAGE_PREFIX}-${CI_PIPELINE_IID}"
```

## Kaniko 构建

```yaml
build-image:
  stage: build_image
  image:
    name: gcr.io/kaniko-project/executor:v1.23.2-debug
    entrypoint: [""]
  script:
    - mkdir -p /kaniko/.docker
    - |
      cat > /kaniko/.docker/config.json <<EOF
      {"auths":{"${IMAGE_REGISTRY}":{"username":"${REGISTRY_USERNAME}","password":"${REGISTRY_PASSWORD}"}}}
      EOF
    - /kaniko/executor --context "${CI_PROJECT_DIR}" --dockerfile "${CI_PROJECT_DIR}/Dockerfile" --destination "${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/${IMAGE_NAME}:${IMAGE_TAG}" --cache=true --cache-repo "${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/${IMAGE_NAME}-cache" --verbosity=info
```

Kaniko 的 executor 镜像也保持上游地址；节点 mirror 或运行环境负责可达性。语言技能需要 build args 时，显式追加 `--build-arg NAME="${NAME}"`，不要把秘密作为 build arg。

多模块项目(`devops/gitlab-ci/dsp/` 是 8 业务模块的真实案例)不要在 pipeline 里硬编码模块列表，用变量驱动：

```yaml
  MODULES:
    value: "auth,gateway,account,ad,gen,open,order,system"
    description: "要构建的模块,逗号分隔"
```
```yaml
    - |
      for module in $(echo "$MODULES" | tr ',' '\n' | xargs); do
        JAR="${CI_PROJECT_DIR}/dsp-${module}/target/dsp-${module}.jar"
        [ -f "$JAR" ] || { echo "ERROR: jar 不存在: $JAR"; exit 1; }
        /kaniko/executor --context "${CI_PROJECT_DIR}/dsp-${module}" \
          --dockerfile "${CI_PROJECT_DIR}/dsp-${module}/Dockerfile" \
          --destination "${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/dsp-${module}:${IMAGE_TAG}" \
          --cache=true --verbosity=info
      done
```

## Kubernetes 发布

发布 job 使用受保护的 `KUBE_CONFIG`，不要把 kubeconfig 写进技能或仓库：

```yaml
deploy-k8s:
  stage: deploy
  image:
    name: bitnami/kubectl:1.31
    entrypoint: [""]
  needs:
    - job: build-image
      artifacts: false
  rules:
    - if: '$CI_COMMIT_REF_NAME != "master" && $DEPLOY_TO_K8S == "true"'
      when: on_success
    - when: manual
      allow_failure: false
  script:
    - install -d -m 700 ~/.kube
    - printf '%s' "${KUBE_CONFIG}" > ~/.kube/config
    - kubectl set image "deployment/${K8S_DEPLOYMENT}" "${K8S_DEPLOYMENT}=${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/${IMAGE_NAME}:${IMAGE_TAG}" -n "${K8S_NAMESPACE}"
    - kubectl rollout status "deployment/${K8S_DEPLOYMENT}" -n "${K8S_NAMESPACE}" --timeout=300s
```

不需要额外 `rollout restart`：`set image` 已产生新的 PodTemplate。master 生产发布必须保持 manual。

多模块部署按同一 `MODULES` 变量循环，逐个 `set image` + `rollout status`；某一个模块 rollout 失败要立刻 exit，不要让后面的模块继续发布：

```yaml
    - |
      for module in $(echo "$MODULES" | tr ',' '\n' | xargs); do
        kubectl set image "deployment/dsp-${module}" \
          "dsp-${module}=${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/dsp-${module}:${IMAGE_TAG}" -n "${K8S_NAMESPACE}"
        kubectl rollout status "deployment/dsp-${module}" -n "${K8S_NAMESPACE}" --timeout=300s || exit 1
      done
```

`KUBE_CONFIG` 用 GitLab **File 型**变量(`cp "$KUBE_CONFIG" ~/.kube/config`)，不要用 printf 拼字符串 —— 见 `devops/gitlab-ci/dsp/.gitlab-ci.yml`。

## 生成前检查

- [ ] 所有版本可复现：基础镜像、构建工具和运行时不用 `latest`
- [ ] 镜像仓库已跟用户确认（客户 Harbor / 本仓库 ACR），凭据来自 masked/protected variables
- [ ] `FROM`/第三方 `image:` 没有被改成 Harbor 地址
- [ ] 镜像 tag 含环境和唯一流水线标识
- [ ] 构建成功后才允许 deploy，deploy 等待 rollout 完成
- [ ] 多模块部署单个 rollout 失败即 exit，不让后续模块继续发布
- [ ] `KUBE_CONFIG`、registry 密码、应用 Secret 不进入镜像、仓库或日志
