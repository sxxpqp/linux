# Linux Ops Notes — AI 协作上下文

> 这是给 Claude 看的。人类索引见 [README.md](README.md)。
> 任何关于本仓库的对话,先读这里,再读对应子目录的 CLAUDE.md / README.md。

## 仓库性质(重要)

- **这是一个个人运维知识库 / 配置实物归档**,不是某一个可运行的应用项目。
- 多数 `.md` 是操作记录、踩坑笔记;多数 `.yaml` / `.conf` / `Dockerfile` 是**生产或测试环境真实在跑的配置**,从服务器同步回来归档。
- 因此:
  - **改这里的文件 ≠ 改生产**。要落到生产,需要 `scp` / `ansible` / `git pull` 推上去再重启服务。
  - 文件里的 IP、域名、密码、订阅 URL 大多是**真实**的,改的时候要小心。
  - 不要在本仓库里"重构代码" —— 这些不是代码,是参考实现。除非明确要求,否则只做**就地修订**(改某个值、补一段注释、修一处错配)。

## 共享基础设施(跨子目录复用)

这些变量在多个子目录里反复出现,以后看到直接套用,不用再问。

### 主机 / 域名

> **核心原则**:任何要走公网的 URL,优先用自建代理(Harbor / Nexus / 1Panel),实在没有再用阿里 / 清华公共镜像,最后才直连官方源。

| 项 | 值 | 备注 |
|---|---|---|
| **镜像拉取入口(Harbor)** | `dockerhub.ihome.sxxpqp.top:8443` | **纯代理(pull-through cache),不接受 push**。所有镜像从这里拉,项目划分见下表 |
| **镜像推送目标(阿里 ACR)** | `registry.cn-hangzhou.aliyuncs.com/sxxpqp/` | 自己构建的镜像统一推这里(用户名 `sxxpqp`,杭州区) |
| MinIO S3 API endpoint | `https://ihome.sxxpqp.top:8443` | S3 客户端 / SDK 用这个,bucket 操作走 API |
| MinIO 控制台 UI | `https://console.ihome.sxxpqp.top:8443` | 管理界面(看 bucket / 用户 / 策略),不是 S3 API |
| Nexus 私服(Base) | `https://nexus.ihome.sxxpqp.top:8443` | **只用于非镜像内容**:raw / helm / 二进制包。镜像已全部迁到 Harbor,不要再用 Nexus 拉镜像 |
| 个人文件中转(chfs) | `https://chfs.sxxpqp.top:8443/chfs/shared/` | 离线包、ISO、压缩包等大文件;HTTP 直接 GET |
| 常用测试主机 | `node02` (192.168.150.253, enp1s0) | network / clash / mihomo |
| **历史镜像入口(已弃用,只读)** | 见 [下方"历史 / 弃用"段](#历史--弃用) | 老脚本里可能见到,但**新写脚本一律用 Harbor** |

### 文件 / 脚本存放约定(重要)

| 类型 | 存放位置 | 拉取方式 |
|---|---|---|
| **脚本**(`.sh` / `.yaml` / `.conf` / 配置模板) | **git 仓库**(本仓库,公开 repo) | Nexus raw-githubusercontent 代理 GitHub,URL 形如 `<nexus>/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/<path>` |
| **大文件**(离线包、ISO、压缩包、二进制) | **chfs 或 MinIO** | chfs 走 HTTP 直拉;MinIO 走 S3 API |
| **镜像** | **Harbor**(代理) / 阿里 ACR(推送) | 见上面 "Harbor 架构" |
| **Helm chart** / GitHub release 二进制 | Nexus 代理 | 见下面 "Nexus 仓库映射" |

**好处**:脚本改了 push 一次 git,新机器执行立即拿到最新版,**不用再手动同步到 chfs**。

**反面案例**:不要把脚本同时维护两份(git + chfs),否则不知不觉就漂移了。

**脚本首行注释约定**:每个 `.sh` 文件必须在其**首行注释块**中包含以下三个标记:

```bash
# 系统: <OS 兼容性>           # 一:目标系统
# 下载: <Nexus raw URL>        # 二:Nexus 下载链接
# 用法: curl -sL <URL> \| bash # 三:一行式执行命令
```

**系统标记(`# 系统:`)** — 说明脚本在什么 OS 上跑:

| 标记值 | 含义 | 例子 |
|---|---|---|
| `CentOS 7+` | CentOS 7 / Rocky Linux / AlmaLinux / RHEL 7+ | yum / dnf 系的脚本 |
| `Ubuntu 20.04+` | Ubuntu 20.04 / 22.04 / 24.04+ | apt 系的脚本 |
| `Debian 11+` | Debian 11 / 12+ | — |
| `Ubuntu \| CentOS` | 脚本内部有 OS 检测,两个都支持 | 安装 Docker 等通用工具 |
| `Linux (systemd)` | 纯 systemd + shell,不挑发行版 | sysctl / 配置模板 |
| `Docker (cross-platform)` | docker-compose / Dockerfile 类,主机 OS 不重要 | 跑容器即可 |
| `Kubernetes (K8s)` | 纯 kubectl / helm 操作,只在 K8s 上跑 | 部署 yaml、helm install |

**判定顺序**:先看脚本内容有无 OS 检测逻辑(`ID=ubuntu` / `os-release` / `yum` / `apt`);没有则从文件路径或文件名推断。

**文件名约定**:

```
<动作>-<目标>[-<OS>][-<架构>][-<方式>].sh
```

| 段 | 可选? | 常见值 |
|---|---|---|
| **动作** | 必填 | `install` / `deploy` / `uninstall` / `backup` / `restore` / `config` / `scale` / `init` |
| **目标** | 必填 | 软件名:docker / nginx / k8s / nvidia-driver / kafka 等 |
| **OS** | 可选 | OS 或平台:centos / ubuntu / wsl-ubuntu / qh(青云) |
| **架构** | 可选 | aarch64 / armv7 / x86_64 |
| **方式** | 可选 | offline / online / binary / source |

**示例**:
- `install-docker-offline.sh` ✅ — 动作+目标+方式
- `install-docker-wsl-ubuntu.sh` ✅ — 动作+目标+平台
- `deploy.sh` ⚠️ — 缺少目标,只在 docker-compose/ 子目录下可接受(目录名补齐了上下文)
- `changplugin.sh` ❌ — 拼写错误,建议改

> **宽松原则**:现有文件保持原名不改。新脚本按此约定命名。不在目录或文件名下划线数量上做死板限制,能让人扫一眼就明白"干什么、在哪跑"即可。

**下载链接约定**:每个 `.sh` 文件必须在首行注释块中包含通过 Nexus 下载的 URL:

```bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/<path>
# 用法: curl -sL <URL> | bash
```

这样在 GitHub 不通的环境下,直接 `curl -sL <Nexus URL> | bash` 就能执行,**无需 git clone**,也无需再记路径。

### Harbor 架构(关键)

Harbor 后端是同一个,但前面挂了 **1Panel/nginx 多前端域名**,**每个域名内部已经做了路径重写**,所以客户端只需要按上游选对应的域名,不用关心 Harbor 内部的项目前缀。

| 上游 | 对应前端域名(1Panel/nginx) | 后端 Harbor 项目 | nginx 内部 rewrite |
|---|---|---|---|
| `docker.io` | `dockerhub.ihome.sxxpqp.top:8443` | `dockerhub` | `/v2/*` → `/v2/dockerhub/*` |
| `ghcr.io` | `ghcr.ihome.sxxpqp.top:8443` | `ghcr` | `/v2/*` → `/v2/ghcr/*` |
| `quay.io` | `quay.ihome.sxxpqp.top:8443` | `quay` | `/v2/*` → `/v2/quay/*` |
| `registry.k8s.io` / `k8s.gcr.io` | `k8s.ihome.sxxpqp.top:8443` | `google_containers` | `/v2/*` → `/v2/google_containers/*` |
| `docker.io`(历史别名) | `dockerhub.ihome.sxxpqp.top:8443` | `dockerhub` | 已弃用, 统一用 `dockerhub` |

### Harbor 项目(直接 pull 时备用)

如果手动 `docker pull huball.../<project>/<image>` 完整路径,对应关系如下:

| Harbor project | 代理上游 |
|---|---|
| `dockerhub` | `docker.io` 全量(library/ 官方 + 用户命名空间都在里面) |
| `library` | (历史项目,不推荐直接用,走 dockerhub 即可) |
| `ghcr` | `ghcr.io` |
| `quay` | `quay.io` |
| `google_containers` | `registry.k8s.io` / `k8s.gcr.io` |

**推荐**:不要直接写 `huball.../<project>/<image>`,而是 **配 docker / containerd 加速源指向对应前端域名**,yaml 里照原样写 `nginx:latest` / `quay.io/...`,客户端 / containerd 自动改写,模板见下面。

### 推镜像(只推阿里云)

**Harbor 不接受 push**。自己构建的镜像统一推 **阿里云 ACR** 命名空间 `sxxpqp`:

```bash
docker login registry.cn-hangzhou.aliyuncs.com   # 用户名 sxxpqp
docker tag <local> registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
docker push      registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
```

之后在 K8s yaml 里 `image:` 直接写 `registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>`(国内节点直连阿里云就够快)。

### 1Panel 反向代理层

1Panel 是 **外网访问内网服务的入口**。所有 `*.ihome.sxxpqp.top:8443` / `*.sxxpqp.top:8443` 这类对外暴露的服务,都是通过 1Panel 反代到内网后端(Nexus / Harbor / chfs 等)。

**约定**:
- 改配置时改后端服务(Nexus 仓库、Harbor 项目、chfs 文件等),**不要动 1Panel 那层**,除非是新增对外域名或调整证书。
- 外网拉镜像 / 拉文件慢时,先排查是后端慢还是 1Panel 那层带宽 / SSL 卸载瓶颈。
- 新增对外服务时:先在内网起好后端 → 再到 1Panel 加反代规则 → 申请 / 复用证书。

### Nexus 仓库映射(按类型)

| 类型 | 仓库路径 | 用法 |
|---|---|---|
| **raw (GitHub raw 文件)** | `/repository/raw-githubusercontent/` | 把 `raw.githubusercontent.com/<x>` → `<base>/<前缀><x>` |
| **raw (GitHub release / 源码 zip)** | `/repository/raw-github/` | 把 `github.com/<x>` → `<base>/<前缀><x>`;Nexus 自动跟随 302 到 codeload / objects 子域 |
| **raw (GitHub API)** | `/repository/raw-github-api/` | 代理 `api.github.com`,用于脚本中获取最新 release 版本号;Dify 脚本用到 |
| **raw (nvidia GitHub Pages)** | `/repository/raw-nvidia/` | 代理 `nvidia.github.io`,用于 nvidia-container-toolkit 的 apt repo + gpgkey;脚本见 `ai/nvidia-container-toolkit/install.sh` |
| **Helm: Grafana** | `/repository/grafana/` | `helm repo add grafana <base>/repository/grafana/` (loki / grafana / mimir / tempo / promtail) |
| **Helm: Prometheus** | `/repository/prometheus-community/` | `helm repo add prometheus-community <base>/repository/prometheus-community/` |
| **Helm: Longhorn** | `/repository/hwlm-longhorn/` | `helm repo add longhorn <base>/repository/hwlm-longhorn/` |
| **Helm: ingress-nginx** | `/repository/helmingress-nginx/` | `helm repo add ingress-nginx <base>/repository/helmingress-nginx/` |
| **Helm: KubeBlocks/apecloud** | `/repository/helm-apecloud/` | `helm repo add kubeblocks <base>/repository/helm-apecloud/` |
| **Jenkins 更新源** | `/repository/jenkins/` | 替换 `updates.jenkins.io/download/` |
| **Claude Code 发布包** | `/repository/claude-code/` | 代理 `downloads.claude.ai/claude-code-releases`,路径不带重复;入口见 `ai/claude-code/bootstrap.cmd` |
| **K8s 二进制** | `/repository/kubernetes-binaries` | `minikube --binary-mirror=<base>/repository/kubernetes-binaries` |

通用模板(其它 helm chart 大多走 Nexus proxy 仓库,名字一般沿用上游 chart 名):

```bash
NEXUS_BASE="https://nexus.ihome.sxxpqp.top:8443/repository"
helm repo add <name>  "${NEXUS_BASE}/<name>/"  --force-update
helm repo update
```

### Docker / containerd 加速源配置

**核心思想**:nginx 多前端已经做了路径重写,客户端只要按上游指向对应前端域名,**不需要 override_path、不需要项目前缀**。

#### Docker(`/etc/docker/daemon.json`)

```json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "registry-mirrors": ["https://dockerhub.ihome.sxxpqp.top:8443"],
  "insecure-registries": [
    "dockerhub.ihome.sxxpqp.top:8443",
    "ghcr.ihome.sxxpqp.top:8443",
    "quay.ihome.sxxpqp.top:8443",
    "k8s.ihome.sxxpqp.top:8443"
  ],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-opts": {"max-size": "100m", "max-file": "5"}
}
```

注:Docker `registry-mirrors` **只对 `docker.io` 生效**。其它上游(ghcr / quay / k8s)Docker 这边没办法,**只能靠 containerd `hosts.toml`**(K8s 集群下都是 containerd,不影响),或者改写 image 名。

#### Containerd(`/etc/containerd/certs.d/<upstream>/hosts.toml`)

每个上游一个目录,直接指向对应前端域名即可(nginx 做 rewrite):

```toml
# /etc/containerd/certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"
[host."https://dockerhub.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
```

完整的 5 个文件模板见 `linux/docker/kind/deploy.sh`(里面有可复用的循环写法,新机器也能跑)。

| 目录 | upstream server | mirror host |
|---|---|---|
| `docker.io/` | `https://registry-1.docker.io` | `dockerhub.ihome.sxxpqp.top:8443` |
| `ghcr.io/` | `https://ghcr.io` | `ghcr.ihome.sxxpqp.top:8443` |
| `quay.io/` | `https://quay.io` | `quay.ihome.sxxpqp.top:8443` |
| `registry.k8s.io/` | `https://registry.k8s.io` | `k8s.ihome.sxxpqp.top:8443` |
| `k8s.gcr.io/` | `https://k8s.gcr.io` | `k8s.ihome.sxxpqp.top:8443` |

`/etc/containerd/config.toml` 里要打开 `config_path = "/etc/containerd/certs.d"` 才会读这些 hosts.toml。

#### 证书

Harbor 前端是自签 / 内网证书,需要:
- Docker:`insecure-registries` 列入所有 *.ihome 域名,或 CA 放到 `/etc/docker/certs.d/<host>:8443/ca.crt`
- Containerd:`skip_verify = true`(模板里已加),或 CA 放到 `/etc/containerd/certs.d/<upstream>/ca.crt`

### 回退策略(Nexus 没代理的源)

**默认偏好**:能改源就改成阿里云 / 清华(TUNA),不要直连官方源。

| 源类型 | 阿里云 | 清华 TUNA |
|---|---|---|
| Docker Hub 镜像加速 | `https://<id>.mirror.aliyuncs.com`(账号专属,需登录控制台获取) | — |
| **Docker CE 安装** | `curl -fsSL https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/install.sh \| bash -s docker --mirror Aliyun` | — |
| **个人 ACR 命名空间** | `registry.cn-hangzhou.aliyuncs.com/sxxpqp/<image>`(杭州区,用户自己推的镜像放这里) | — |
| 阿里 ACR(其它命名空间,只读引用) | 见下表 | — |
| CentOS / RHEL / EPEL yum | `https://mirrors.aliyun.com/centos/` / `epel/` | `https://mirrors.tuna.tsinghua.edu.cn/centos/` |
| Ubuntu / Debian apt | `https://mirrors.aliyun.com/ubuntu/` | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu/` |
| PyPI | `https://mirrors.aliyun.com/pypi/simple/` | `https://pypi.tuna.tsinghua.edu.cn/simple/` |
| npm | `https://registry.npmmirror.com` | — |
| Go proxy | `https://goproxy.cn` | — |
| Kubernetes 二进制 | `https://mirrors.aliyun.com/kubernetes/` | — |
| Helm charts(无 Nexus 代理时) | — | `https://mirror.azure.cn/kubernetes/charts/` 或上游 |
| GitHub release / 源码 zip | 走 Nexus `raw-github`:`github.com/<x>` → `<base>/repository/raw-github/<x>` | — |

**决策顺序**:
1. **自建代理**(Harbor / Nexus / 1Panel 反代域名) —— 优先,内网最快
2. 阿里 / 清华公共镜像 —— 公网国内可达,自建没覆盖时用
3. 上游官方源 —— 基本不通,只作兜底文档参考

**重要**:看到任何外网 URL(docker.io / quay.io / ghcr.io / github.com / raw.githubusercontent.com / k8s.gcr.io / charts.* 等),**第一反应是查 CLAUDE.md 里有没有对应的自建代理**,直接套用,不要默认上游。

### 阿里 ACR 命名空间速查(项目里出现过的)

写 K8s yaml / Dockerfile / docker-compose 引用镜像时,优先按这个表选源:

| 命名空间 | 用途 | 示例 |
|---|---|---|
| `sxxpqp` | **自己推的镜像**(nps, npc, minio, jellyfin, moviepilot, csi-* 等) | `registry.cn-hangzhou.aliyuncs.com/sxxpqp/nps` |
| `turingv` | 公司用的 CI builder 镜像(devops 流水线引用) | `registry.cn-hangzhou.aliyuncs.com/turingv/builder-nodejs:v1` |
| `chenby` | 第三方搬运的 k8s 系列镜像(pause / kube-* / defaultbackend 等),离线安装文档里常见 | `registry.cn-hangzhou.aliyuncs.com/chenby/pause:3.6` |
| `kubesphereio` | 北京区,KubeSphere 官方在阿里云的镜像 | `registry.cn-beijing.aliyuncs.com/kubesphereio/<x>` |
| `ingress-nginx` | ingress-nginx 官方在阿里云的镜像 | `registry.cn-hangzhou.aliyuncs.com/ingress-nginx/controller:<tag>` |

**推镜像约定**:用户名 `sxxpqp`,只往 `cn-hangzhou` 的 `sxxpqp` 命名空间推。

```bash
# 推镜像标准流程
docker login registry.cn-hangzhou.aliyuncs.com  # 用户名 sxxpqp
docker tag <local-image> registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
docker push registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
```

### 已存在的参考脚本 / 文档

需要看具体怎么用时,直接 Read 这些文件:

- 一键安装菜单 + 私有仓库变量:`kubernetes/kubeadm/k8s-setup-menu.sh`
- Helm 私服 + 离线包用法:`kubernetes/kubeblocks/install.sh`, `kubernetes/loki/install.sh`
- daemon.json 完整示例:`kubernetes/learn/v1.28.3-CentOS-binary-install-IPv6-IPv4-Three-Masters-Two-Slaves-Offline.md`(约 1485 行)
- raw 代理的实际使用:`network/mihomo/config.yaml`(`rule-providers` 段)

### 历史 / 弃用

以下地址在老脚本 / yaml 里可能出现,**只读,不要在新写的内容里使用**。

| 地址 | 原用途 | 现在状态 |
|---|---|---|
| `dockerhub.sxxpqp.top` / `iharbor.sxxpqp.top` | 更早一代镜像加速 | 已弃用,改用 Harbor 多前端域名 |
| `harbor.iot.store:8085` | 旧业务 Harbor(`turing-kubesphere/*` 系列) | 业务镜像仍在用,但**新镜像推阿里 ACR**;helm chart 在 `kubernetes/harbor/values.yaml` |
| `core.harbor.iot.store` | 旧业务 Harbor UI | 见上 |
| `020300.ihome.sxxpqp.top:8443` | Tekton 镜像源 | **未确认**,可能是 Harbor 的另一个 nginx 别名;遇到 tekton 部署时再确认 |
| `mirror.ghproxy.com` | GitHub 加速 | 已不可用,改走 Nexus `raw-github` |

注:`ghcr.ihome.sxxpqp.top:8443` / `quay.ihome.sxxpqp.top:8443` / `k8s.ihome.sxxpqp.top:8443` / `dockerhub.ihome.sxxpqp.top:8443` / `dockerhub.ihome.sxxpqp.top:8443` 等 **没有列在"弃用"里** —— 它们是 **Harbor 的现役 nginx 多前端别名**,继续使用,见上面 "Harbor 架构" 段。

参考实现:`linux/docker/kind/deploy.sh`(已更新成新架构,可复用)。

## 子目录优先级 / 当前活跃区域

按"最近活跃 + 最常被问"排序,不在表里的子目录都是历史归档:

| 子目录 | 用途 | 是否有 CLAUDE.md |
|---|---|---|
| `network/mihomo/` | mihomo 代理(裸核 + TUN,跑在 node02) | ✅ 有专用 CLAUDE.md |
| `clash/` | clash 客户端配置(已被 mihomo 取代,留作参考) | 无 |
| `kubernetes/` | K8s 生产配置归档,内容最多最杂,问之前先看子目录 README | 无 |
| `docker/docker-compose/` | docker-compose 服务模板(mysql / nginx / redis 等) | 无 |
| `devops/` | Jenkins 流水线 + 各业务 K8s Pod 模板(多集群:saas / sd / test / tsl / tzj / whrr / ztwx / huawei-saas 等) | 无 |

需要在某个子目录建立独立上下文时,在那里加一份 CLAUDE.md(参考 `network/mihomo/CLAUDE.md` 的写法)。

## 跨项目约定

1. **每个一级子目录都有自己的 README.md** —— 被问到某个主题时,先 Read 对应 README,而不是凭空猜。
2. **状态标记**(README.md 里有):`✅ 生产验证` / `验证过` / `学习笔记`。改生产验证类的文件要更谨慎。
3. **同一项目可能有多个集群版本**(尤其 devops/ 下):`saas / sd / tsl / tzj / whrr / ztwx / huawei-saas / gstest` 等是不同客户/环境,改一个不一定能套到另一个,要先确认对方需要的是哪个集群。
4. **同步脚本** `gitpush.sh` 在顶层 —— 不要随便改,这是用户提交笔记到远端的入口。

## 对话风格偏好(从历史会话归纳)

- 用户用中文沟通,但命令、日志、变量名保留英文。
- 回答**先给结论 + 直接可执行的命令**,再补原理 / 排查路径。
- 用户喜欢 **表格 + 代码块 + 分点** 的结构,排版清晰比文字密度更重要。
- 用户会贴 `journalctl` / `ip route` / `systemctl status` 的原始输出 —— 直接基于输出回答,不要让用户"再跑一遍 X 命令"除非真的缺信息。
- 修改配置文件时:**优先用 Edit 工具改本地文件**,然后告诉用户 `scp` / `git push` 推到服务器的命令,不要只在回复里贴 diff。
- **每次修改文件后,主动询问是否 git push**,并给出建议的 commit message(格式:`bash gitpush.sh "<message>"`)。

## 已知踩坑(跨项目通用)

1. **GitHub raw 直连基本不通**:任何 `raw.githubusercontent.com` 的 URL,优先改成走 Nexus raw 代理。
2. **GitHub release zip 直连基本不通**:同上,或者改用 `chfs.sxxpqp.top` 上预先放好的离线包。
3. **CentOS / RHEL 默认带 firewalld + SELinux**:网络类排障第一步先 `systemctl status firewalld` + `getenforce`。
4. **systemd-resolved**:Ubuntu 系会占 53 端口,跑 DNS 类服务前先 `systemctl status systemd-resolved`。
5. **libvirt virbr0**:测试机上常见的虚拟网桥,跟物理网卡分流时要排除,自动检测出口网卡的程序经常误选它。

## 不要做的事

- ❌ 不要主动建 README.md / 文档,除非用户明确要求(顶层 README 已经很全)。
- ❌ 不要把生产 IP / 密码 "脱敏",这是用户自己的内网,本来就是真实值。
- ❌ 不要把 yaml 重排序 / 重格式化,只改用户要求改的字段。
- ❌ 不要在不熟悉的子目录大改,先 Read 该子目录 README + 至少一个示例文件再动手。
