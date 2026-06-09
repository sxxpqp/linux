# 业务应用接入 ArgoCD GitOps — 完整模板 + 踩坑总结

> 状态: ✅ 生产验证(vue3-demo 跑通)
> 集群: kh (172.16.150.128), K8s 1.28, Calico BGP-LB + ingress-nginx
> ArgoCD 装在本集群 argocd ns,装法见上一级 [README.md](../README.md)
> GitLab CE 18.4.0 自托管,`http://192.168.150.252:9980`(SSH `:9922`)
> 真实样板项目: `D:\code\vue3-demo`(直接对照可读)

GitLab CI 推 Harbor 镜像 → 改 git manifest → ArgoCD 监听 git → sync 集群,**整链路 git 是真理源,CI 不直接 kubectl**。

---

## 适用场景 / 不适用场景

| 场景 | 用 GitOps(本模板) | 用推模式(kubectl set image) |
|---|---|---|
| 业务前后端 / Web 服务 / 长生命周期应用 | ✅ | ⚠ |
| 多环境(dev / uat / prod) | ✅ Kustomize overlay | ✅ |
| 高频回滚 / 灰度 | ✅ git revert / Argo Rollouts | ⚠ |
| 一次性任务 / Job / CronJob 部署 | ⚠ | ✅ |
| 集群无外网 / CI 在外网 | ✅ pull 模式集群拉 git | ❌ CI 推不进集群 |
| 团队不熟 GitOps | ⚠(学习曲线) | ✅ |

本仓库已有推模式参考:[`devops/gitlab-ci/dsp/`](../../../devops/gitlab-ci/dsp/);本模板补 GitOps 路径。

---

## 全景架构

```
开发者 → git push master(代码)
                    ↓
              ┌─ GitLab CI ─────────────────────┐
              │                                  │
              │ install / build / scan          │
              │           ↓                      │
              │ build-image (kaniko)             │
              │   IMAGE_TAG=master-ff49f0b5     │
              │   推 ──→ Harbor: myapp:<tag>    │
              │           ↓                      │
              │ update-manifest                  │
              │   sed 改 k8s/deployment.yaml    │
              │   git push 回 master            │
              │   (commit [skip ci] 防死循环)   │
              └──────────────────────────────────┘
                    ↓
              GitLab master 新 commit
                    ↓
              ArgoCD repo-server 轮询(默认 3min,或 webhook 推秒级)
                    ↓
              ArgoCD diff → apply → 集群滚动新镜像
                    ↓
              用户访问 myapp.ihome.sxxpqp.top → ingress-nginx → Pod
```

---

## 文件清单(本模板包含什么)

| 文件 | 用途 |
|---|---|
| [templates/namespace.yaml](templates/namespace.yaml) | 业务 ns + imagePullSecret 注释说明(Harbor Public 时不要 secret) |
| [templates/deployment.yaml](templates/deployment.yaml) | Deployment + Service + Ingress + PDB 一站式(4 个 K8s 资源单文件) |
| [templates/argocd-application.yaml](templates/argocd-application.yaml) | ArgoCD Application CR,装 argocd ns,watch git 业务 repo |
| [templates/argocd-repo-secret.yaml.example](templates/argocd-repo-secret.yaml.example) | git repo 凭据(声明式),`.gitignore` 忽略真值文件 |
| [gitlab-ci-snippet.yml](gitlab-ci-snippet.yml) | `.gitlab-ci.yml` 的 `update-manifest` stage + 顶部 variables + build-image rules |

---

## 接入流程(新项目从 0 到上线)

### 第 1 步:拷模板到业务 repo

```bash
cd /path/to/your-business-repo
mkdir -p k8s
cp /path/to/linux/kubernetes/argocd/app-onboarding/templates/*.yaml k8s/
cp /path/to/linux/kubernetes/argocd/app-onboarding/templates/*.yaml.example k8s/

# 全文替换占位符 myapp → 实际应用名(假设 = vue3-demo)
sed -i 's/myapp/vue3-demo/g' k8s/*.yaml k8s/*.yaml.example

# 手动改这几处:
#   k8s/deployment.yaml      → image 行的 Harbor 项目 / 初始 tag / Ingress host
#   k8s/argocd-application.yaml → source.repoURL 改成你的 GitLab repo URL
```

### 第 2 步:加 `.gitignore` 防真 secret 入 git

```bash
cat >> .gitignore <<'EOF'

# K8s Secret 真值文件(.example 模板入 git,真值人工填后 apply,不入 git)
k8s/*-secret.yaml
!k8s/*-secret.yaml.example
EOF
```

### 第 3 步:GitLab 项目配 update-manifest push 权限

⚠ 这步是 GitLab UI 操作,**3 个挂钩点对齐缺一就 401/403**:

**3.1 创建 Project Access Token**

`vue3-demo 项目 → Settings → Access Tokens → Add new token`

| 字段 | 值 |
|---|---|
| Token name | `gitlab-ci-update-manifest` |
| Role | **Maintainer**(master protected → 必须) |
| Scopes | ✅ **`write_repository`**(只勾这一个) |
| Expiration | 90 天后,到期前轮换 |

复制 token + 记 bot username `project_<id>_bot_<hash>`。

**3.2 master Protected branch 含 bot**

`Settings → Repository → Protected branches → master`

- "Allowed to push and merge" 默认含 Maintainers → bot 自动覆盖 ✅
- 不放心:"Add member" 显式加 `project_<id>_bot_<hash>`

**3.3 加 CI/CD Variable**

`Settings → CI/CD → Variables → Add variable`

| 字段 | 值 |
|---|---|
| Key | `GITLAB_PUSH_TOKEN` |
| Value | 3.1 的 token |
| Type | Variable |
| **Protected** | **✅ Yes**(master protected 强制要求) |
| **Masked** | ✅ Yes |

### 第 4 步:加 update-manifest stage

把 [gitlab-ci-snippet.yml](gitlab-ci-snippet.yml) 里的 `update-manifest` 段贴到你 `.gitlab-ci.yml` 末尾,顶部 `stages:` 加上 `update-manifest`。

参考完整版:`D:\code\vue3-demo\.gitlab-ci.yml`。

### 第 5 步:配 ArgoCD repo 凭据 + apply Application

```bash
# 集群上(能 kubectl + argocd 的机器)
git clone <your-repo> && cd <your-repo>

# repo 凭据(声明式,推荐)
cp k8s/argocd-repo-secret.yaml.example k8s/argocd-repo-secret.yaml
vim k8s/argocd-repo-secret.yaml   # 改 stringData 三字段(明文,不用 base64)
kubectl apply -f k8s/argocd-repo-secret.yaml
argocd repo list   # STATUS=Successful = 通

# apply Application(一次性,后续都是 git push 驱动)
kubectl apply -f k8s/argocd-application.yaml

# 看状态
argocd app get <app-name> --refresh
```

### 第 6 步:DNS / 路由

把 Ingress host 解析到 ingress-nginx 的 LB IP:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller   # EXTERNAL-IP
# 本地 /etc/hosts 临时加,生产去 DNS 配
```

---

## IMAGE_TAG 双轨策略

| 触发 | IMAGE_TAG | 用途 |
|---|---|---|
| `git push master`(日常) | `master-ff49f0b5`(branch + short SHA) | 高频迭代 / 测试环境 |
| `git push origin v1.0.0`(发版) | `v1.0.0`(git tag 原名) | 正式发布 / 留存档 / 客户对接 |

### ⚠ 实现要点:必须用 `rules:variables`,**不要**用 bash 默认值语法

**错误**(踩过坑,导致 ArgoCD failed to unmarshal nil 事故):
```yaml
variables:
  IMAGE_TAG: "${CI_COMMIT_TAG:-${CI_COMMIT_REF_SLUG}-${CI_COMMIT_SHORT_SHA}}"
  # GitLab CI variables 段不解析 bash ${VAR:-fb} 默认值语法 → IMAGE_TAG="" → manifest 被改坏
```

**正确**:
```yaml
variables:
  IMAGE_TAG: "${CI_COMMIT_REF_SLUG}-${CI_COMMIT_SHORT_SHA}"   # 顶部默认

build-image:
  rules:
    - if: '$CI_COMMIT_TAG'
      variables:
        IMAGE_TAG: "${CI_COMMIT_TAG}"                          # tag pipeline 时 override
    - if: '$CI_COMMIT_BRANCH == "master"'
# update-manifest 段也加同样的 rules:variables,否则 sed 改的 tag 跟 build-image 推的镜像对不上
```

### 发版命令

```bash
git checkout master && git pull
git tag v1.0.0
git push origin v1.0.0
# GitLab tag pipeline 自动跑:build-image 推 myapp:v1.0.0 + update-manifest 改 deployment.yaml + push
# ArgoCD sync 集群滚动到 v1.0.0
```

---

## 回退方法

| 紧急程度 | 场景 | 用 |
|---|---|---|
| **日常 95%**(发现 bug,业务还在跑) | 无在线损失 | **`git revert <bad-commit> && git push`** |
| **救火 5%**(生产正在 500) | 在线损失 | `argocd app rollback` + 关 selfHeal 止血;**并行** git revert 修因 |

```bash
# 日常回退
git log --oneline -5
git revert <bad-commit> --no-edit
git push origin master
# 等 ArgoCD sync(默认 3min,或 hard refresh)

# 救火(SRE on-call)
argocd app set <app> --sync-policy none           # 关 selfHeal
argocd app rollback <app> <good-revision>          # 秒级回到上版
# ... 同时让开发写 git revert MR,merge 后 ...
argocd app set <app> --sync-policy automated --auto-prune --self-heal
```

⚠ **反模式**:只 `argocd app rollback` 不修 git → selfHeal=true 几秒后又拉坏代码。**rollback 是止血不是回退**。

---

## 踩坑表(全部踩过,逐条说原因 + 改法)

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | `update-manifest` job 报 `GITLAB_PUSH_TOKEN 未注入` | CI Variable 没勾 Protected,master 是 protected branch pipeline 拿不到 | 第 3.3 步 Variable Protected=Yes |
| 2 | `git push` 返回 `403 not allowed to push to protected branch` | Project Access Token 不是 Maintainer / bot user 不在 Allowed to push | 重建 Maintainer token + 3.2 步加 bot |
| 3 | `git push` 返回 `401 Unauthorized` | token scope 没勾 write_repository / token 过期 | 重建 token,scope 只勾 write_repository |
| 4 | `git push` 返回 `connection refused` | URL 写死 `https://` 但 GitLab 跑 `http:9980` | 用 `${CI_SERVER_PROTOCOL}` 自动取 |
| 5 | **ArgoCD `Failed to unmarshal deployment.yaml: <nil>`** | CI 把 image tag 改成空了(`vue3-demo:` 后面没 tag) | 根因是 IMAGE_TAG 表达式用了 bash `${VAR:-fb}` GitLab CI 不解析 → 改 rules:variables,再补 IMAGE_TAG 非空 sanity check |
| 6 | pipeline 死循环触发 | update-manifest 的 commit message 没 `[skip ci]` | commit message 必须含 `[skip ci]` |
| 7 | Pod ImagePullBackOff | Harbor 项目 Private 但没建 imagePullSecret / 跨网段连不到 Harbor | 看 namespace.yaml 顶部注释建 secret;跨网段先 `curl :6443/v2/` 验通 |
| 8 | ArgoCD `Application` 删了 ns 还在 Terminating | finalizer 等 controller 处理但 controller 已被删 | `kubectl patch ns <ns> --type=json -p '[{"op":"remove","path":"/spec/finalizers"}]'`,见 k8s-cleanup-stuck skill |
| 9 | 改 image tag 撞 commit(CI 改 vs 人改) | 两边同时改同一行 | **不要手工改 image tag**,只让 CI 改;真要回滚走 `git revert` |
| 10 | `argocd app rollback` 后几秒被撤回到坏状态 | selfHeal=true,git 还是坏的 | 救火必须**同时**关 selfHeal,且并行 git revert |
| 11 | repo Secret 不小心 commit 到 git | `.gitignore` 没配 / 真值文件名是 `.yaml` 而不是 `.yaml.example` | 第 2 步 `.gitignore` 配好,真值文件用纯 `.yaml`,模板用 `.yaml.example` |
| 12 | ArgoCD 一直 OutOfSync 但 git 没改 | repo-server 缓存 / git 凭据失效 | `kubectl -n argocd logs deploy/argocd-repo-server --tail=50`;`argocd repo list` 看 STATUS |

---

## 跟仓库其它部分的关系

| 上游 | 是 | 不是 |
|---|---|---|
| 镜像走每节点 mirror | ✅ `quay.io/ghcr.io/docker.io` 节点 mirror 已配,YAML image 一个字不改 | 不要在 deployment.yaml 改 `image: <mirror>/...` |
| Calico BGP-LB | ✅ Ingress LB IP 从 `172.16.150.200/29` 池自动分 | 不要给 ingress-nginx Service 配 NodePort |
| ingress-nginx | ✅ ingressClassName: nginx,host-based 路由 | TLS 暂不开,有 cert-manager 再加 |
| Harbor `hub.wishfoxs.com:6443` | ⚠ 跨网段不一定通,部署前 `curl :6443/v2/` 验 | 不通走 `infra-url-rewrite` skill 推到 ACR |
| `devops/gitlab-ci/dsp/` | ❌ 那是推模式(kubectl set image),本模板是 GitOps 拉模式 | 不要混着用 |

---

## 后续可考虑的升级

| 想做 | 怎么做 | 状态 |
|---|---|---|
| ArgoCD 秒级同步 | GitLab 项目 Webhooks 推 `https://<argocd>/api/webhook` | 待 |
| Harbor tag immutability | Harbor 项目 → Policy → Tag immutability rule `master-*` + `v*` | 待 |
| Harbor tag retention(防 tag 撑爆) | Harbor 项目 → Tag Retention 保留最近 30 个 | 待 |
| repo Secret 也入 git | SealedSecrets / External Secrets / SOPS | 待 |
| 多环境分离 | Kustomize base + overlays/{dev,prod},两个 Application 各指 overlay | 待 |
| 金丝雀 / 蓝绿 | Argo Rollouts | 待 |
| 镜像 digest 不可变引用 | ArgoCD Image Updater(自动追 `@sha256:...`) | 待 |
