# 基础设施参考(按需 Read)

> 配置 Docker / containerd 加速、写 Nexus URL、查 Harbor 项目、找阿里 ACR 命名空间时翻这里。
> 脚本约定见 [script-conventions.md](script-conventions.md)。

## Harbor 项目(直接 pull 时备用)

如果手动 `docker pull huball.../<project>/<image>` 完整路径,对应关系如下:

| Harbor project | 代理上游 |
|---|---|
| `dockerhub` | `docker.io` 全量(library/ 官方 + 用户命名空间都在里面) |
| `library` | (历史项目,不推荐直接用,走 dockerhub 即可) |
| `ghcr` | `ghcr.io` |
| `quay` | `quay.io` |
| `google_containers` | `registry.k8s.io` / `k8s.gcr.io` |

**推荐**:不要直接写 `huball.../<project>/<image>`,而是 **配 docker / containerd 加速源指向对应前端域名**,yaml 里照原样写 `nginx:latest` / `quay.io/...`,客户端 / containerd 自动改写,模板见下面。

## 1Panel 反向代理层

1Panel 是 **外网访问内网服务的入口**。所有 `*.ihome.sxxpqp.top:8443` / `*.sxxpqp.top:8443` 这类对外暴露的服务,都是通过 1Panel 反代到内网后端(Nexus / Harbor / chfs 等)。

**约定**:
- 改配置时改后端服务(Nexus 仓库、Harbor 项目、chfs 文件等),**不要动 1Panel 那层**,除非是新增对外域名或调整证书。
- 外网拉镜像 / 拉文件慢时,先排查是后端慢还是 1Panel 那层带宽 / SSL 卸载瓶颈。
- 新增对外服务时:先在内网起好后端 → 再到 1Panel 加反代规则 → 申请 / 复用证书。

## Nexus 仓库映射(按类型)

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

## Docker / containerd 加速源配置

**核心思想**:nginx 多前端已经做了路径重写,客户端只要按上游指向对应前端域名,**不需要 override_path、不需要项目前缀**。

### Docker(`/etc/docker/daemon.json`)

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

### Containerd(`/etc/containerd/certs.d/<upstream>/hosts.toml`)

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

### 证书

Harbor 前端是自签 / 内网证书,需要:
- Docker:`insecure-registries` 列入所有 *.ihome 域名,或 CA 放到 `/etc/docker/certs.d/<host>:8443/ca.crt`
- Containerd:`skip_verify = true`(模板里已加),或 CA 放到 `/etc/containerd/certs.d/<upstream>/ca.crt`

## 回退策略(Nexus 没代理的源)

**默认偏好**:能改源就改成阿里云 / 清华(TUNA),不要直连官方源。

| 源类型 | 阿里云 | 清华 TUNA |
|---|---|---|
| Docker Hub 镜像加速 | `https://<id>.mirror.aliyuncs.com`(账号专属,需登录控制台获取) | — |
| **Docker CE 安装** | `curl -fsSL https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/install.sh \| bash -s docker --mirror Aliyun` | — |
| **个人 ACR 命名空间** | `registry.cn-hangzhou.aliyuncs.com/sxxpqp/<image>`(杭州区,用户自己推的镜像放这里) | — |
| 阿里 ACR(其它命名空间,只读引用) | 见下表 | — |
| CentOS / RHEL / EPEL yum | `https://mirrors.aliyun.com/centos/` / `epel/` | `https://mirrors.tuna.tsinghua.edu.cn/centos/` |
| Ubuntu / Debian apt | `https://mirrors.aliyun.com/ubuntu/` | `https://mirrors.tuna.tsinghua.edu.cn/ubuntu/` |
| PyPI / PyTorch / conda / maven 等(完整阿里云镜像汇总) | 见 [aliyun-mirrors.md](../aliyun-mirrors.md) | `https://pypi.tuna.tsinghua.edu.cn/simple/` 等 |
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

## 阿里 ACR 命名空间速查(项目里出现过的)

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

## 已存在的参考脚本 / 文档

需要看具体怎么用时,直接 Read 这些文件:

- 一键安装菜单 + 私有仓库变量:`kubernetes/kubeadm/k8s-setup-menu.sh`
- Helm 私服 + 离线包用法:`kubernetes/kubeblocks/install.sh`, `kubernetes/loki/install.sh`
- daemon.json 完整示例:`kubernetes/learn/v1.28.3-CentOS-binary-install-IPv6-IPv4-Three-Masters-Two-Slaves-Offline.md`(约 1485 行)
- raw 代理的实际使用:`network/mihomo/config.yaml`(`rule-providers` 段)

## 历史 / 弃用

以下地址在老脚本 / yaml 里可能出现,**只读,不要在新写的内容里使用**。

| 地址 | 原用途 | 现在状态 |
|---|---|---|
| `dockerhub.sxxpqp.top` / `iharbor.sxxpqp.top` | 更早一代镜像加速 | 已弃用,改用 Harbor 多前端域名 |
| `harbor.iot.store:8085` | 旧业务 Harbor(`turing-kubesphere/*` 系列) | 业务镜像仍在用,但**新镜像推阿里 ACR**;helm chart 在 `kubernetes/harbor/values.yaml` |
| `core.harbor.iot.store` | 旧业务 Harbor UI | 见上 |
| `020300.ihome.sxxpqp.top:8443` | Tekton 镜像源 | **未确认**,可能是 Harbor 的另一个 nginx 别名;遇到 tekton 部署时再确认 |
| `mirror.ghproxy.com` | GitHub 加速 | 已不可用,改走 Nexus `raw-github` |

注:`ghcr.ihome.sxxpqp.top:8443` / `quay.ihome.sxxpqp.top:8443` / `k8s.ihome.sxxpqp.top:8443` / `dockerhub.ihome.sxxpqp.top:8443` 等 **没有列在"弃用"里** —— 它们是 **Harbor 的现役 nginx 多前端别名**,继续使用,见 CLAUDE.md "Harbor 架构" 段。

参考实现:`linux/docker/kind/deploy.sh`(已更新成新架构,可复用)。
