---
name: infra-url-rewrite
description: Rewrite public source URLs (non-image) to the user's internal proxies (Nexus / chfs / Aliyun ACR). Use whenever a script, YAML, or command references raw.githubusercontent.com, github.com release ZIPs, upstream Helm chart repos, or other public file/binary downloads. Triggers on phrases like "github 拉不动", "raw 拉不动", "换成 Nexus", "走 chfs", "raw.githubusercontent", "release 下载不动". DO NOT rewrite container image references — containerd mirror config handles those transparently (keep upstream image refs in YAML/Dockerfile unchanged). Also use when authoring new install.sh in this repo — public file URLs should be rewritten by default.
---

# 公网 URL → 自建代理改写

> 项目: https://github.com/sxxpqp/linux
> 项目 CLAUDE.md "已知踩坑 #1":GitHub raw / release 直连基本不通。**默认改走自建代理**。

## ⚠ 核心原则:镜像加速只在 2 个脚本里配,其他地方不改 image

**镜像相关的改动 = 节点上跑这 2 个脚本,每个节点一次**(顺序固定):

1. [docker/containerd/install.sh](../../../docker/containerd/install.sh) —— 装 containerd 时 sed config.toml **3 处**:
   - `SystemdCgroup = true`
   - `sandbox_image → registry.aliyuncs.com/google_containers/pause:x.x`(**bootstrap fallback**:节点第一个拉的镜像走阿里 direct,不依赖 Harbor / 不需要 TLS skip,最稳)
   - `config_path = "/etc/containerd/certs.d"`(开 hosts.toml lookup)
2. [docker/containerd/mirrors.sh](../../../docker/containerd/mirrors.sh) —— 写齐 5 份 `/etc/containerd/certs.d/<host>/hosts.toml`(docker.io / ghcr.io / quay.io / registry.k8s.io → Harbor + ACR direct)

**之后 YAML / Dockerfile / 安装脚本里的 `image:` / `FROM` 一律保持上游不动**,kubelet 通过 containerd 自动走 mirror。

> **为什么 sandbox_image 例外、要走阿里 direct 而不靠 hosts.toml**:`pause` 是节点起的第一个容器,bootstrap 时 hosts.toml 可能还没写齐 / containerd 还没重读,任何拉不动都会让整个 kubelet 起不来。阿里 direct 没有 TLS skip 也不依赖 Harbor,是最可靠的 fallback。这是**唯一**允许 sed config.toml 改 image 的场景,**写进了 install.sh 里**,不要再在别处复刻。

- ✅ YAML 里继续写 `image: registry.k8s.io/autoscaling/vpa-recommender:1.0.0`
- ✅ Dockerfile 里继续写 `FROM docker.io/library/python:3.11-slim`
- ❌ **不要** sed 替换成 `k8s.ihome.sxxpqp.top:8443/...`
- ❌ **不要** 替换成 `dockerhub.ihome.sxxpqp.top:8443/...`
- ❌ **不要**写 install.sh 时加 `IMG_REGISTRY` 变量去改 image
- ❌ **不要**复刻 `sed -i 's#registry.k8s.io#registry.aliyuncs.com/google_containers#g' config.toml` —— 这只在 `docker/containerd/install.sh` 里改 `sandbox_image`,**不**是给业务镜像用的通用模式

**为什么这么定**:
- YAML / Dockerfile 保持上游可移植,换集群 / 复制到外网环境不用改文件
- mirror 配置在节点层一次性配好,所有 Pod 自动走代理
- 真要换 mirror 域名,改 `docker/containerd/mirrors.sh` 一处,推到所有节点重启 containerd 即可,**不用扫全仓库 sed**

**唯一例外:自己构建推阿里 ACR** — `image: registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>` 是显式写,不是改写(mirrors.sh 给 ACR 配了 direct hosts.toml,走 ACR 不走 Harbor)。

## 改写映射表(权威源)

### 非镜像内容(Nexus raw 代理 + chfs)

这才是这个 skill 主要处理的:**文件/脚本/二进制**,containerd 管不了。

| 原 URL | 改成 |
|---|---|
| `https://raw.githubusercontent.com/<owner>/<repo>/<ref>/<path>` | `https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/<owner>/<repo>/<ref>/<path>` |
| `https://github.com/<owner>/<repo>/releases/download/<tag>/<file>` | 优先放 **chfs**:`https://chfs.sxxpqp.top:8443/chfs/shared/<file>`(自己 wget 上传到 chfs 一次) |
| `https://charts.<upstream>/<chart>` Helm chart | Nexus helm 代理(`https://nexus.ihome.sxxpqp.top:8443/repository/helm-<upstream>/...`) |
| 二进制 / 离线包 | chfs 优先;其次 `nexus.ihome.sxxpqp.top:8443/repository/raw-...` |
| `https://gitlab.com/<…>/raw/<…>` 等其他 raw 源 | 同 Nexus raw,新建对应 proxy repo |

### 镜像 push(自己构建只走阿里 ACR)

Harbor 是纯拉取代理,**不接受 push**。自己 build 的镜像统一推阿里 ACR 命名空间 `sxxpqp`:

```bash
docker login registry.cn-hangzhou.aliyuncs.com   # 用户名 sxxpqp
docker tag <local> registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
docker push      registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
```

K8s yaml `image:` 字段显式写 `registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>`(国内节点直连阿里就够快,且不依赖 containerd mirror)。

### S3 / 对象存储

| 用途 | URL |
|---|---|
| S3 API endpoint(SDK / `aws s3 --endpoint-url`) | `https://ihome.sxxpqp.top:8443` |
| MinIO 控制台 | `https://console.ihome.sxxpqp.top:8443` |

## 改写规则(给脚本 / YAML / Dockerfile 用)

### Dockerfile

```Dockerfile
# ✓ FROM 保持上游不动(build 在 containerd 节点上,mirror 自动生效)
FROM docker.io/library/python:3.11-slim

# ✗ 错的:RUN 里直连公网 raw
RUN curl -fsSL https://raw.githubusercontent.com/foo/bar/main/install.sh | bash

# ✓ 对的:RUN 走 Nexus raw 代理
RUN curl -fsSLk https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/foo/bar/main/install.sh | bash
```

> 注意 `curl -k`:Nexus 自签名证书要跳过校验。
> 注意 build 环境:**只有 containerd 配了 mirror 的节点**上 build,FROM 才走代理。在没配 mirror 的笔记本上 build,FROM 直连官方;这是为什么 Dockerfile 里不改 FROM —— 让节点配置决定走不走代理。

### K8s YAML

```yaml
# ✓ image 保持上游不动,containerd mirror 自动转发
image: ghcr.io/projectcalico/operator:v1.34.0
image: registry.k8s.io/autoscaling/vpa-recommender:1.0.0
image: docker.io/library/nginx:alpine

# ✓ 自建镜像显式写阿里 ACR
image: registry.cn-hangzhou.aliyuncs.com/sxxpqp/my-app:v1.2.3
```

### Shell install.sh(项目标准头)

```bash
NEXUS_RAW="${NEXUS_RAW:-https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent}"

# 拉 yaml / sh / 二进制 → 走 Nexus
curl -fsSLk "${NEXUS_RAW}/projectcalico/calico/v3.28.2/manifests/calico.yaml" -o calico.yaml

# 允许外网环境覆盖默认
# NEXUS_RAW=https://raw.githubusercontent.com bash install.sh ...

# 镜像不要改写!保持上游字符串,kubectl apply 后 kubelet 通过节点 containerd mirror 自动转发
# ✗ 不要做:sed -i 's|registry.k8s.io|k8s.ihome.sxxpqp.top:8443|g' xxx.yaml
```

### containerd 加速 hosts.toml(这里才是镜像走代理的真正位置)

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://docker.io"
[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true   # 内网自签
```

**别手写**:`mirrors.sh` 一把梭,**完整 5 条**(4 个 Harbor pull-through proxy + 阿里 ACR direct),一次写完:

```bash
bash docker/containerd/mirrors.sh                        # 写 5 份 hosts.toml
systemctl restart containerd                             # 让 containerd 重读
ctr -n k8s.io image pull docker.io/library/nginx:alpine  # 验证
```

**这就是全部 5 条 mirror,exhaustive list:**

| `/etc/containerd/certs.d/<上游>/hosts.toml` | 指向 | 模式 |
|---|---|---|
| `docker.io` | `dockerhub.ihome.sxxpqp.top:8443` | Harbor pull-through |
| `ghcr.io` | `ghcr.ihome.sxxpqp.top:8443` | Harbor pull-through |
| `quay.io` | `quay.ihome.sxxpqp.top:8443` | Harbor pull-through |
| `registry.k8s.io`(兼容 `k8s.gcr.io`) | `k8s.ihome.sxxpqp.top:8443` | Harbor pull-through |
| `registry.cn-hangzhou.aliyuncs.com` | direct(`server = "..."`,无 `[host."..."]` 块) | 直连阿里 ACR |

**列表之外的 registry 一律不动**:`gcr.io` / `mcr.microsoft.com` / 业务自建 registry / 任何其它上游都**直连**,既不在 mirrors.sh 加新条目,也不在 YAML 改 image。真有节点拉不下来才考虑加 mirror,不要预防性加。

完整脚本见 [docker/containerd/mirrors.sh](../../../docker/containerd/mirrors.sh);Harbor 多前端域名内部已经 rewrite(`/v2/*` → `/v2/<project>/*`),客户端不用关心 Harbor 项目前缀。

## 历史 / 弃用(看到要替换 — 仅 containerd 配置 / 文档里)

- `dockerhub.sxxpqp.top:8443` → 改 `dockerhub.ihome.sxxpqp.top:8443`
- `harbor.iot.store:8085` → 改 `dockerhub.ihome.sxxpqp.top:8443`
- `mirror.ghproxy.com` → 改 `nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent`

> 注意:历史 yaml 里已有的 `dockerhub.ihome.sxxpqp.top:8443/xxx` 这种**显式带代理域名的 image**,改回上游 `docker.io/xxx` 是更好的(让 containerd mirror 接管)。但不要做大规模 sed 重排,只在你正好改这个文件时顺手改。

## 改写时的判断流

```
拿到一个公网 URL
  │
  ├─ 是容器镜像?(docker pull / image: 字段 / Dockerfile FROM)
  │   └─ 【保持上游不动】 不论是不是 mirrors.sh 列表里的 5 条上游:
  │       - 列表内(docker.io / ghcr.io / quay.io / registry.k8s.io / ACR):节点 containerd 已经配好,自动转发
  │       - 列表外(gcr.io / mcr.microsoft.com / 业务自建):直连,也不动 image,不预防性加 mirror
  │       特例:自己 build 的 → 显式写 registry.cn-hangzhou.aliyuncs.com/sxxpqp/...
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
| `sed -i 's\|docker.io\|dockerhub.ihome.sxxpqp.top:8443\|g' xxx.yaml` | 保持 `docker.io/...` 不动,让 containerd mirror 转发 |
| 装时改写 `image:` 字段 | image 字段不动,**靠 `bash docker/containerd/mirrors.sh` 已配好的 hosts.toml** |
| `FROM dockerhub.ihome.sxxpqp.top:8443/python:3.11-slim` | `FROM docker.io/library/python:3.11-slim`(节点 containerd 转发) |
| 业务 install.sh 里抄 `sed 's#registry.k8s.io#registry.aliyuncs.com/google_containers#g' config.toml` | 这条只在 `docker/containerd/install.sh` 里改 `sandbox_image`(节点 bootstrap),业务脚本不动 config.toml,不动 image |
| `curl https://raw.githubusercontent.com/...` | NEXUS_RAW 代理 |
| GitHub release 直接 `wget` | 先 chfs |
| 把推送目标写成 dockerhub.ihome.sxxpqp.top | Harbor 不接受 push,改阿里 ACR |
| 用 `harbor.iot.store:8085` 这种老地址 | 看"历史 / 弃用"表替换(仅 containerd 配置 / 文档) |

## 何时调用此 skill

- 写 install.sh / 安装脚本,涉及 `curl` 拉 **yaml / sh / 二进制**(**不**包括 `docker pull`)
- 写或改 `kubernetes/containerd/` 下的 hosts.toml / config.toml
- 用户贴 `curl: (6) Could not resolve` / `404 Not Found` 等 **raw / release** 拉取报错
- 用户问"这个 raw URL 走代理怎么写"
- 用户问"chfs / Nexus / 阿里 ACR 该用哪个"

## 何时**不**调用此 skill(避免误用)

- ❌ 用户问"image: 字段写什么" — image 字段保持上游不动(本 skill 不改 image)
- ❌ `docker pull docker.io/xxx` 拉不动 — 不是 URL 改写问题,是节点 containerd mirror 没配,查 hosts.toml
- ❌ 在 YAML 里看到 `docker.io/nginx:alpine` 觉得"应该改写" — 不,这是正确的写法
