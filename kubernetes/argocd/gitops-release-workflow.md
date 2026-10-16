# CI + Argo CD 多环境发布约定

> 状态：方案记录，尚未完成端到端验证。

## 职责和仓库

- 业务代码仓库：保存源码，由 Jenkins / GitLab CI 测试、构建并推送镜像。
- 部署配置仓库：保存环境部署配置，建议独立于本运维知识库；生产 main 分支受保护。
- Argo CD：读取部署配置仓库 main 分支的指定环境目录；开启自动同步后部署到对应集群。
- CI 更新部署配置并提交 MR/PR；Argo CD 不负责源码编译或镜像构建，也不需要部署仓库写权限。

## 环境触发规则

| 业务仓库触发来源 | CI 行为 | 部署配置更新方式 |
|---|---|---|
| 测试分支 test | 测试、构建、推送镜像 | 更新 test/，可按团队权限自动合入 |
| 预发分支 release/* | 测试、构建、推送镜像 | 更新 staging/，按需审核合入 |
| 发布 tag v* | 校验发布提交、镜像和测试结果；必要时构建正式镜像 | 自动创建生产部署 MR，审核后合入 main，更新 prod/ |

tag 是提交的固定标记，不是分支。普通提交和业务 MR 仍应执行测试；发布 tag 仅作为正式发布入口。

```text
业务源码提交 → CI 测试、构建镜像 → 预发验证
                                      ↓
在已验证提交上创建受保护发布 tag v1.3.0
                                      ↓
CI 确认并提升预发验证过的同一镜像 digest
                                      ↓
创建部署分支 → 修改 prod/ 镜像引用 → 提 MR 到部署仓库 main
                                      ↓
人工审核合并 → Argo CD 自动同步 → 验证健康状态和业务
```

生产优先提升预发验证过的同一镜像 digest，避免重新构建产生不同内容。若 tag 流水线重新构建了镜像，新产物需要重新验证，不能视为预发已经验证过。

## 镜像如何更新

CI 推送镜像成功后，在部署仓库的新分支中精确修改目标容器的 image。例如 order-api 从：

```text
registry.cn-hangzhou.aliyuncs.com/sxxpqp/order-api:v1.2.9
```

更新为：

```text
registry.cn-hangzhou.aliyuncs.com/sxxpqp/order-api:v1.3.0
```

可使用 Mike Farah yq v4 精确修改容器字段，或使用 Kustomize images / Helm values 管理版本。生产要求更严格时固定 image digest。普通 YAML 中的 $IMAGE_TAG 不会被 Argo CD 自动替换。

修改后 CI 提交更新分支并创建 MR/PR，不能直接推送受保护 main。这里合并的是部署配置变更，不是“合并 tag”。CI 必须明确限定环境文件路径，避免一次修改所有环境。

部署仓库目录示例：

```text
test/order-api/
staging/order-api/
prod/order-api/
```

每个环境对应独立 Argo CD Application，绑定各自目录和目标集群。Git 变更检测和同步有延迟，并非提交后立即完成。

## 权限与发布边界

- 限制生产发布 tag 的创建权限；发布 tag 和已发布镜像 tag 不覆盖、不移动。
- 保护部署仓库 main，CI 机器人仅能推送更新分支和创建 MR/PR；生产合并由有权限的审核者执行。
- 不允许任意业务分支通过创建 tag 绕过发布规则；tag 流水线校验提交是否来自允许发布的历史及对应验证结果。
- CI 凭据使用平台受保护的凭据管理，不写入源码或部署 YAML；明确保护变量可用于哪些分支和 tag。
- 业务仓库 CI 构建推送后更新部署仓库；避免部署提交再次触发业务镜像构建，形成循环。
- CI 更新镜像版本不替换上游 registry 为代理地址；节点镜像加速仍由 containerd mirror 负责。

## 验收和回退

生产 MR 至少确认目标环境、镜像 digest、预发结果和数据库兼容性。合并后检查 Argo CD Synced / Healthy、Deployment rollout 和实际业务请求；仅资源健康不代表业务验证通过。

回退通过新的部署 MR 将镜像引用改回上一版本，合并后由 Argo CD 同步。不要只手工改集群，否则可能被 Git 中的期望配置覆盖。镜像回退不会自动回退数据库迁移，数据库变更需要单独设计兼容和恢复方案。
