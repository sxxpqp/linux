# DSP GitLab CI 流水线

> 多模块 Java 项目(8 业务模块 + 4 层依赖链)的 GitLab CI 模板 + API 触发用法。
> 仅手动触发,push 不会自动构建。

## 文件清单

| 文件 | 用途 |
|---|---|
| [.gitlab-ci.yml](.gitlab-ci.yml) | 流水线本体,放到项目根目录即可 |
| [README.md](README.md) | 本文档(API 触发 + 变量速查) |

## 模块结构

```
dsp-dependencies          ← BOM,所有版本号在这里
    ↓
dsp-common (parent)
    ├─ dsp-common-api
    └─ dsp-common-core
    ↓
dsp-api                   ← REST 接口契约
    ↓
dsp-third-sdk             ← 第三方对接(支付/广告等)
    ↓
dsp-{auth,gateway,account,ad,gen,open,order,system}   ← 业务模块
```

Stage 1 (`build-deps`) 一次性把上面 4 层依赖装到本地 Maven 仓库,通过 GitLab cache 跨流水线复用。
**只有 pom 改了才需要重建依赖**(设 `REBUILD_DEPS=true`)。

## CI/CD Variables 必填项

在 GitLab 项目 **Settings → CI/CD → Variables** 配置(全部勾 `Masked` + `Protected`):

| Key | Type | 说明 |
|---|---|---|
| `HARBOR_USERNAME` | Variable | Harbor 推镜像账号 |
| `HARBOR_PASSWORD` | Variable | Harbor 推镜像密码 |
| `KUBE_CONFIG` | File | 目标 K8s 集群的 kubeconfig 文件 |

## 前置准备(API 触发)

```bash
# 填入你自己的值
PROJECT_ID=<项目数字ID>        # GitLab 项目页 → Settings → General 顶部
PRIVATE_TOKEN=<your-token>    # User Settings → Access Tokens(需 api 权限)
GITLAB=http://gitlab.example.com
```

> 也可用 **Trigger Token**:Settings → CI/CD → Pipeline triggers → 添加后复制 token,
> 调用路径改为 `/trigger/pipeline`,参数改为 `token=` + `ref=`(见末尾示例)。

---

## 常用场景

### 1. 构建并部署(最常用)

```bash
curl -X POST "$GITLAB/api/v4/projects/$PROJECT_ID/pipeline" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "ref": "master",
    "variables": [
      {"key": "VERSION",      "value": "uat-1.2.0"},
      {"key": "MODULES",      "value": "auth,gateway,account"},
      {"key": "K8S_NAMESPACE","value": "dsp-uat"},
      {"key": "DEPLOY_TO_K8S","value": "true"}
    ]
  }'
```

### 2. 只构建镜像,不部署 K8s

```bash
curl -X POST "$GITLAB/api/v4/projects/$PROJECT_ID/pipeline" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "ref": "master",
    "variables": [
      {"key": "VERSION",      "value": "uat-1.2.0"},
      {"key": "MODULES",      "value": "auth,gateway"},
      {"key": "DEPLOY_TO_K8S","value": "false"}
    ]
  }'
```

### 3. 只重建依赖链(pom 有变更时)

```bash
curl -X POST "$GITLAB/api/v4/projects/$PROJECT_ID/pipeline" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "ref": "master",
    "variables": [
      {"key": "IS_DEPLOY_COMMON","value": "true"},
      {"key": "REBUILD_DEPS",    "value": "true"}
    ]
  }'
```

> `IS_DEPLOY_COMMON=true` 会跳过 package / build_image / deploy 三个 stage,只跑依赖链。

### 4. 全量构建所有模块并部署生产

```bash
curl -X POST "$GITLAB/api/v4/projects/$PROJECT_ID/pipeline" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "ref": "master",
    "variables": [
      {"key": "VERSION",      "value": "prod-1.2.0"},
      {"key": "MODULES",      "value": "auth,gateway,account,ad,gen,open,order,system"},
      {"key": "K8S_NAMESPACE","value": "dsp-prod"},
      {"key": "DEPLOY_TO_K8S","value": "true"},
      {"key": "REBUILD_DEPS", "value": "false"}
    ]
  }'
```

---

## 变量速查

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `VERSION` | `1.0.1-SNAPSHOT` | 镜像 tag,建议格式 `uat-x.x.x` / `prod-x.x.x` |
| `MODULES` | 全部 8 个 | 逗号分隔,单独构建某个填一个即可 |
| `IS_DEPLOY_COMMON` | `false` | `true` = 只跑依赖链,跳过后续所有 stage |
| `DEPLOY_TO_K8S` | `true` | `false` = 构建镜像后不更新 K8s |
| `REBUILD_DEPS` | `false` | `true` = 强制重建依赖,pom 改动时用 |
| `K8S_NAMESPACE` | `dsp-test` | `dsp-test` / `dsp-uat` / `dsp-prod` |

---

## 查询流水线状态

```bash
# 列出最近流水线(返回包含 pipeline id)
curl -s "$GITLAB/api/v4/projects/$PROJECT_ID/pipelines?per_page=5" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN" | \
  python3 -c "import sys,json; [print(p['id'], p['status'], p['ref'], p.get('created_at','')) for p in json.load(sys.stdin)]"

# 查看某条流水线的 jobs
PIPELINE_ID=<pipeline_id>
curl -s "$GITLAB/api/v4/projects/$PROJECT_ID/pipelines/$PIPELINE_ID/jobs" \
  -H "PRIVATE-TOKEN: $PRIVATE_TOKEN" | \
  python3 -c "import sys,json; [print(j['name'], j['status']) for j in json.load(sys.stdin)]"
```

---

## 用 Trigger Token(不用个人 Token 时)

```bash
TRIGGER_TOKEN=<trigger-token>
curl -X POST "$GITLAB/api/v4/projects/$PROJECT_ID/trigger/pipeline" \
  --form "token=$TRIGGER_TOKEN" \
  --form "ref=master" \
  --form "variables[VERSION]=uat-1.2.0" \
  --form "variables[MODULES]=auth,gateway" \
  --form "variables[DEPLOY_TO_K8S]=true"
```

> `ref` 可换成 `test` / `develop` / 任意分支名。

---

## 注意事项

1. **Runner tags**:模板里 `tags: [docker]`,要求 GitLab Runner 注册时打了 `docker` 标签;没用 docker executor 就改成对应的 tag。
2. **Kaniko 缓存**:`--cache=true` 会在 Harbor 里建 `<project>/cache` 仓库存中间层,要确保账号有写权限。
3. **kubectl 版本**:`KUBECTL_IMAGE` 选的版本必须能跟目标集群对话(差不超过 ±1 minor)。
4. **依赖 cache 失效场景**:换 runner / cache 过期 / 改 `CI_COMMIT_REF_SLUG`(切分支)。出现"找不到 dsp-common 包"先看 `build-deps` 是不是跳过了。
