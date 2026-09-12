---
name: ci-gitlab-kaniko
description: Use when a project needs a GitLab CI pipeline that builds an image with Kaniko, pushes it to Aliyun ACR, and optionally deploys it to Kubernetes. Do not use for containerd mirror setup or language-specific build instructions.
---

# GitLab + Kaniko CI 基线

语言技能只负责项目检测、依赖安装和产物构建；流水线公共部分统一按本技能执行。

## 镜像边界

- Dockerfile `FROM` 和 K8s 第三方 `image:` 保持上游地址，例如 `docker.io/library/nginx:1.27-alpine`、`gcr.io/distroless/static-debian12:nonroot`。
- 节点通过 containerd mirror 加速；不要在 CI 或 YAML 里写 Harbor 代理域名，也不要用 `sed` 改 image。
- 自己构建的镜像推送阿里 ACR：

```yaml
variables:
  IMAGE_REGISTRY: registry.cn-hangzhou.aliyuncs.com
  IMAGE_NAMESPACE: sxxpqp
  IMAGE_NAME: change-me
  IMAGE_TAG: "${CI_COMMIT_REF_SLUG}-${CI_PIPELINE_IID}"
```

ACR 用户名、密码使用 GitLab masked/protected variables，不写入仓库、日志或 Dockerfile。

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
      {"auths":{"${IMAGE_REGISTRY}":{"username":"${ACR_USERNAME}","password":"${ACR_PASSWORD}"}}}
      EOF
    - /kaniko/executor --context "${CI_PROJECT_DIR}" --dockerfile "${CI_PROJECT_DIR}/Dockerfile" --destination "${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/${IMAGE_NAME}:${IMAGE_TAG}" --cache=true --cache-repo "${IMAGE_REGISTRY}/${IMAGE_NAMESPACE}/${IMAGE_NAME}-cache" --verbosity=info
```

Kaniko 的 executor 镜像也保持上游地址；节点 mirror 或运行环境负责可达性。语言技能需要 build args 时，显式追加 `--build-arg NAME="${NAME}"`，不要把秘密作为 build arg。

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

## 生成前检查

- [ ] 所有版本可复现：基础镜像、构建工具和运行时不用 `latest`
- [ ] ACR 凭据来自 masked/protected variables
- [ ] `FROM`/第三方 `image:` 没有被改成 Harbor 地址
- [ ] 镜像 tag 含环境和唯一流水线标识
- [ ] 构建成功后才允许 deploy，deploy 等待 rollout 完成
- [ ] `KUBE_CONFIG`、ACR 密码、应用 Secret 不进入镜像、仓库或日志
