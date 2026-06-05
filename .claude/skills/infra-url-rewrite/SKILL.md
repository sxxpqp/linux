---
name: infra-url-rewrite
description: Rewrite public registry / source URLs to the user's internal proxies (Harbor / Nexus / chfs / Aliyun ACR). Use whenever a script, YAML, or command references docker.io, ghcr.io, quay.io, registry.k8s.io, k8s.gcr.io, raw.githubusercontent.com, github.com release ZIPs, or upstream Helm chart repos. Triggers on phrases like "github 拉不动", "镜像拉不动", "换成 Nexus", "走代理", "raw.githubusercontent", "走 Harbor", or any URL containing the listed upstream hosts. Also use when authoring new install.sh / Dockerfile / k8s YAML in this repo — public URLs should be rewritten by default.
---

# 公网 URL → 自建代理改写

> 项目: https://github.com/sxxpqp/linux
> 项目 CLAUDE.md "已知踩坑 #1-#2":GitHub raw 直连基本不通,镜像直连看运气。**默认改走自建代理**。

## 改写映射表(权威源)

### 容器镜像(Harbor 拉取代理)

Harbor 后端是同一个,前面挂了 1Panel/nginx 多域名,**每个域名内部已经 rewrite**,客户端只按上游选域名即可,不用关心 Harbor 项目前缀。

| 原 URL 前缀 | 改成 | 内部 rewrite |
|---|---|---|
| `docker.io/library/<image>` 或 `<image>:<tag>` | `dockerhub.ihome.sxxpqp.top:8443/<image>:<tag>` | `/v2/*` → `/v2/dockerhub/*` |
| `ghcr.io/<owner>/<image>` | `ghcr.ihome.sxxpqp.top:8443/<owner>/<image>` | `/v2/*` → `/v2/ghcr/*` |
| `quay.io/<owner>/<image>` | `quay.ihome.sxxpqp.top:8443/<owner>/<image>` | `/v2/*` → `/v2/quay/*` |
| `registry.k8s.io/<...>` / `k8s.gcr.io/<...>` | `k8s.ihome.sxxpqp.top:8443/<...>` | `/v2/*` → `/v2/google_containers/*` |

**例**:`docker.io/library/nginx:alpine` → `dockerhub.ihome.sxxpqp.top:8443/nginx:alpine`

### 推送(只走阿里云 ACR)

Harbor **不接受 push**。自己构建的统一推阿里 ACR 命名空间 `sxxpqp`:

```bash
docker login registry.cn-hangzhou.aliyuncs.com   # 用户名 sxxpqp
docker tag <local> registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
docker push      registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
```

K8s yaml `image:` 字段直接写 `registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>`,国内节点直连阿里就够快。

### 非镜像内容(Nexus raw 代理 + chfs)

| 原 URL | 改成 |
|---|---|
| `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>` | `https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/<owner>/<repo>/<ref>/<path>` |
| `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>` | 优先放 **chfs**:`https://chfs.sxxpqp.top:8443/chfs/shared/<file>`(自己 wget 上传到 chfs 一次) |
| `https://charts.<upstream>/<chart>` Helm chart | Nexus helm 代理(`https://nexus.ihome.sxxpqp.top:8443/repository/helm-<upstream>/...`) |
| 二进制 / 离线包 | chfs 优先;其次 `nexus.ihome.sxxpqp.top:8443/repository/raw-...` |

### S3 / 对象存储

| 用途 | URL |
|---|---|
| S3 API endpoint(SDK / `aws s3 --endpoint-url`) | `https://ihome.sxxpqp.top:8443` |
| MinIO 控制台 | `https://console.ihome.sxxpqp.top:8443` |

## 改写规则(给脚本 / YAML / Dockerfile 用)

### Dockerfile

```Dockerfile
# ✗ 直连
FROM docker.io/library/python:3.11-slim
RUN curl -fsSL https://raw.githubusercontent.com/foo/bar/main/install.sh | bash

# ✓ 走代理
FROM dockerhub.ihome.sxxpqp.top:8443/python:3.11-slim
RUN curl -fsSLk https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/foo/bar/main/install.sh | bash
```

> 注意 `curl -k`:自签名证书要跳过校验。

### K8s YAML

```yaml
# ✗
image: ghcr.io/projectcalico/operator:v1.34.0

# ✓
image: ghcr.ihome.sxxpqp.top:8443/projectcalico/operator:v1.34.0
```

### Shell install.sh(项目标准头)

```bash
NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"

# 拉文件
curl -fsSLk "${NEXUS_RAW}/projectcalico/calico/v3.28.2/manifests/calico.yaml" -o calico.yaml

# 允许用户外网环境直连官方源(覆盖默认)
# NEXUS_RAW=https://raw.githubusercontent.com bash install.sh ...
```

### Docker / containerd 加速 hosts.toml

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://docker.io"
[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true   # 内网自签
```

四套(docker.io / ghcr.io / quay.io / registry.k8s.io)都按上面映射写,完整模板见 `docs/infra-reference.md`。

## 历史 / 弃用(看到要替换)

- `dockerhub.sxxpqp.top:8443` → 改 `dockerhub.ihome.sxxpqp.top:8443`
- `harbor.iot.store:8085` → 改 `dockerhub.ihome.sxxpqp.top:8443`
- `mirror.ghproxy.com` → 改 `nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent`

## 改写时的判断流

```
拿到一个公网 URL
  │
  ├─ 是容器镜像?(出现在 docker pull / image: 字段)
  │   └─ 看上游域名,按 Harbor 多域名映射表替换
  │       特例:自己构建的 → 直接写阿里 ACR 路径
  │
  ├─ 是 raw 文件?(raw.githubusercontent.com / gitlab.com/.../raw/...)
  │   └─ 替换前缀为 Nexus raw 代理
  │
  ├─ 是 GitHub release 下载?(.../releases/download/...)
  │   └─ 优先 chfs(用户手动上传过的)
  │      没上传过:wget 一次,scp 到 chfs,文档里记 chfs URL
  │
  └─ 是 Helm chart / 别的包源?
      └─ 检查 Nexus 有没有对应的代理 repo,没有就提议建一个
```

## 反模式

| ✗ | ✓ |
|---|---|
| 直接 `docker pull docker.io/...` | 走 dockerhub.ihome.sxxpqp.top:8443 |
| `curl https://raw.githubusercontent.com/...` | NEXUS_RAW 代理 |
| GitHub release 直接 `wget` | 先 chfs |
| `image: nginx:alpine`(隐式 docker.io) | 显式写 `dockerhub.ihome.sxxpqp.top:8443/nginx:alpine` |
| 把推送目标写成 dockerhub.ihome.sxxpqp.top | Harbor 不接受 push,改阿里 ACR |
| 用 `harbor.iot.store:8085` 这种老地址 | 看"历史 / 弃用"表替换 |

## 何时调用此 skill

- 写 / 改 `Dockerfile`、`docker-compose.yml`、K8s `image:` 字段
- 写 install.sh / 安装脚本,涉及 `curl` 拉 yaml / sh / 二进制
- 用户贴 `error pulling image ... net/http: TLS handshake timeout` 等公网超时报错
- 用户问"这个 URL 走代理怎么写"
- 在 `kubernetes/`、`devops/`、`docker/` 子目录下新增配置
