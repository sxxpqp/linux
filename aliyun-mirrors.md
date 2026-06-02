# 阿里云镜像源速查

国内开发 / 部署优先用阿里云镜像源(公网 `mirrors.aliyun.com` 通用,阿里云 ECS 上换成 `mirrors.cloud.aliyuncs.com` 免公网流量+更快)。

> 总入口: <https://developer.aliyun.com/mirror/>
> ECS 内网入口(只在 ECS 上能解析): `mirrors.cloud.aliyuncs.com` —— **HTTP 不带 TLS,要 `--trusted-host`**

## 公网 vs ECS 内网 速换表

| 公网域名 | ECS 内网域名 | 说明 |
|---|---|---|
| `mirrors.aliyun.com` | `mirrors.cloud.aliyuncs.com` | 用 `sed -i 's|mirrors.aliyun.com|mirrors.cloud.aliyuncs.com|g'` 一把全换 |
| `registry.cn-hangzhou.aliyuncs.com` | `registry-vpc.cn-hangzhou.aliyuncs.com` | ACR 推/拉镜像时区分,VPC 域名免公网流量 |

## Python 生态

### PyPI

```bash
# 公网
pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/

# 阿里云 ECS 内网(免流量,需要 trusted-host 因为是 HTTP)
pip config set global.index-url http://mirrors.cloud.aliyuncs.com/pypi/simple/
pip config set install.trusted-host mirrors.cloud.aliyuncs.com
```

### PyTorch wheels

入口:`https://mirrors.aliyun.com/pytorch-wheels/`
**必须带 CUDA 版本子目录**,跟上游一样。可选目录:

| 子目录 | 用途 |
|---|---|
| `cpu` | 纯 CPU 版 |
| `cu118` | CUDA 11.8 |
| `cu121` | CUDA 12.1 |
| `cu124` | CUDA 12.4 |
| `cu126` | CUDA 12.6 |

```bash
# 装 torch + CUDA 12.1 版
pip install torch torchvision torchaudio \
  --index-url https://mirrors.aliyun.com/pytorch-wheels/cu121

# CPU 版
pip install torch --index-url https://mirrors.aliyun.com/pytorch-wheels/cpu
```

### Conda / Anaconda

```bash
# 公网
conda config --add channels https://mirrors.aliyun.com/anaconda/pkgs/main
conda config --add channels https://mirrors.aliyun.com/anaconda/pkgs/free
conda config --add channels https://mirrors.aliyun.com/anaconda/cloud/conda-forge
conda config --set show_channel_urls yes
```

## OS / 包管理

### CentOS / RHEL / Rocky / AlmaLinux

```bash
# 替换 base + epel
sed -i 's|^mirrorlist=|#mirrorlist=|g;
        s|^#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|g' \
        /etc/yum.repos.d/CentOS-*.repo
yum clean all && yum makecache
```

| Repo | URL |
|---|---|
| Base | `https://mirrors.aliyun.com/centos/$releasever/os/$basearch/` |
| Updates | `https://mirrors.aliyun.com/centos/$releasever/updates/$basearch/` |
| EPEL | `https://mirrors.aliyun.com/epel/$releasever/Everything/$basearch/` |
| CentOS-Vault(7.9 EOL 后) | `https://mirrors.aliyun.com/centos-vault/7.9.2009/` |

### Ubuntu / Debian

```bash
# Ubuntu
sed -i 's|//[^/]*archive.ubuntu.com|//mirrors.aliyun.com|g;
        s|//[^/]*security.ubuntu.com|//mirrors.aliyun.com|g' \
        /etc/apt/sources.list
apt update
```

| 系统 | URL 模板 |
|---|---|
| Ubuntu | `https://mirrors.aliyun.com/ubuntu/` |
| Debian | `https://mirrors.aliyun.com/debian/` |
| Alpine | `https://mirrors.aliyun.com/alpine/v3.18/main/` |

## 容器 / OCI

### Docker CE 安装

```bash
# 走 get.docker.com + --mirror Aliyun(自动配阿里源)
curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun

# 或仓库内 docker/install.sh 已经做了同样的事
curl -fsSL https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/install.sh | bash -s docker --mirror Aliyun
```

### Docker Hub 加速器

**控制台账号专属**,每个阿里云账号独立 ID:

```
登录 https://cr.console.aliyun.com/cn-hangzhou/instances/mirrors
→ 获取属于你的 https://<account-id>.mirror.aliyuncs.com
→ 写到 /etc/docker/daemon.json registry-mirrors
```

### 阿里云容器镜像服务(ACR)

| 用途 | URL |
|---|---|
| 公网拉/推 | `registry.cn-hangzhou.aliyuncs.com/<namespace>/<image>:<tag>` |
| **ECS VPC 内网拉/推** | `registry-vpc.cn-hangzhou.aliyuncs.com/<namespace>/<image>:<tag>` |
| 个人命名空间(本仓库自构建用) | `registry.cn-hangzhou.aliyuncs.com/sxxpqp/<image>` |

杭州区是常用区,其他区把 `cn-hangzhou` 换成 `cn-beijing` / `cn-shenzhen` / `cn-shanghai` 等。

## Kubernetes 生态

| 用途 | URL |
|---|---|
| k8s 二进制(kubelet / kubectl / kubeadm) | `https://mirrors.aliyun.com/kubernetes/` |
| k8s 新源(社区拆分后 v1.24+) | `https://mirrors.aliyun.com/kubernetes-new/core/` |
| Helm | 阿里云无,用 `https://mirror.azure.cn/kubernetes/charts/` 或自家 Nexus |
| Pause / kube-* 系统镜像 | `registry.cn-hangzhou.aliyuncs.com/chenby/pause:3.6` 等(第三方搬运,见 CLAUDE.md "阿里 ACR 命名空间速查") |

## JVM 生态

### Maven / Gradle

```xml
<!-- ~/.m2/settings.xml -->
<mirror>
  <id>aliyun</id>
  <mirrorOf>*</mirrorOf>
  <url>https://maven.aliyun.com/repository/public</url>
</mirror>
```

| 仓库 | URL |
|---|---|
| central + jcenter 聚合 | `https://maven.aliyun.com/repository/public` |
| Spring | `https://maven.aliyun.com/repository/spring` |
| Google | `https://maven.aliyun.com/repository/google` |
| Gradle plugin | `https://maven.aliyun.com/repository/gradle-plugin` |

## Node.js 生态

> `registry.npmmirror.com` 是 **淘宝团队维护**(2022 从 `registry.npm.taobao.org` 迁过来),阿里旗下,国内首选。
> 二进制依赖(node-sass / sharp / electron / puppeteer 等)必须单独配镜像,否则会去外网拉死。

### npm

```bash
# ① 全局换源
npm config set registry https://registry.npmmirror.com
npm config get registry        # 验证

# ② 单次使用(不改全局)
npm install <pkg> --registry=https://registry.npmmirror.com
```

### yarn / pnpm / bun

```bash
yarn config set registry https://registry.npmmirror.com
pnpm config set registry https://registry.npmmirror.com
bun config set registry https://registry.npmmirror.com   # 1.0+
```

### 二进制依赖镜像(关键!不配会卡死)

写到 `~/.npmrc`(用户级)或 `<project>/.npmrc`(项目级):

```ini
registry=https://registry.npmmirror.com

# Node 二进制(node-gyp / nvm 等需要)
disturl=https://registry.npmmirror.com/-/binary/node

# 常见原生模块
sass_binary_site=https://registry.npmmirror.com/-/binary/node-sass
sharp_dist_base_url=https://registry.npmmirror.com/-/binary/sharp-libvips
canvas_binary_host_mirror=https://registry.npmmirror.com/-/binary/canvas

# Electron / Chromium 类(最容易卡)
electron_mirror=https://registry.npmmirror.com/-/binary/electron/
electron_builder_binaries_mirror=https://registry.npmmirror.com/-/binary/electron-builder-binaries/

# Puppeteer / Playwright(headless 浏览器)
puppeteer_download_host=https://registry.npmmirror.com/-/binary
PLAYWRIGHT_DOWNLOAD_HOST=https://registry.npmmirror.com/-/binary/playwright

# 浏览器驱动
chromedriver_cdnurl=https://registry.npmmirror.com/-/binary/chromedriver
selenium_cdnurl=https://registry.npmmirror.com/-/binary/selenium
operadriver_cdnurl=https://registry.npmmirror.com/-/binary/operadriver
phantomjs_cdnurl=https://registry.npmmirror.com/-/binary/phantomjs
```

### Node 版本管理(nvm / fnm)

```bash
# nvm 镜像(写到 ~/.bashrc 或 ~/.zshrc)
export NVM_NODEJS_ORG_MIRROR=https://registry.npmmirror.com/-/binary/node
export NVM_IOJS_ORG_MIRROR=https://registry.npmmirror.com/-/binary/iojs
nvm install 20

# fnm 镜像
fnm install --node-dist-mirror https://registry.npmmirror.com/-/binary/node 20

# n 镜像
N_NODE_MIRROR=https://registry.npmmirror.com/-/binary/node n latest
```

### nrm 一键切换工具(推荐)

```bash
npm install -g nrm
nrm ls               # 列源: npm / taobao / cnpm / yarn / tencent
nrm use taobao       # 一键切到淘宝(实际就是 registry.npmmirror.com)
nrm test taobao      # 测延迟
```

## Go 生态

```bash
# Go modules proxy(七牛云,**不是阿里云**)
go env -w GOPROXY=https://goproxy.cn,direct
go env -w GOSUMDB=sum.golang.google.cn
go env -w GO111MODULE=on
```

阿里云也有 Go proxy: `https://mirrors.aliyun.com/goproxy/`,但 `goproxy.cn` 名气更大、覆盖更全,**推荐 `goproxy.cn`**。

## Rust 生态

阿里云无 crates 镜像,走清华 TUNA:

```toml
# ~/.cargo/config.toml
[source.crates-io]
replace-with = 'tuna'

[source.tuna]
registry = "https://mirrors.tuna.tsinghua.edu.cn/git/crates.io-index.git"

# 或用稀疏索引(更快,2023+ 版本支持)
[source.tuna-sparse]
registry = "sparse+https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/"
```

## 阿里云没覆盖的常见源(走清华 TUNA)

| 源 | 清华 URL |
|---|---|
| Homebrew core/cask | `https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/` |
| Rust crates 索引 | `https://mirrors.tuna.tsinghua.edu.cn/git/crates.io-index.git` |
| Eclipse release | `https://mirrors.tuna.tsinghua.edu.cn/eclipse/` |
| LLVM apt | `https://mirrors.tuna.tsinghua.edu.cn/llvm-apt/` |
| GitHub release / 源码 zip | 走本仓库 Nexus `raw-github`,见 CLAUDE.md "Nexus 仓库映射" |

## ECS 内网决策顺序

在阿里云 ECS 上跑的所有任务(CI runner / 容器构建 / K8s 节点),按这个优先级:

1. 🥇 **`mirrors.cloud.aliyuncs.com`**(ECS 内网,HTTP,免流量,需 `--trusted-host`)
2. 🥈 **`registry-vpc.cn-hangzhou.aliyuncs.com`**(ACR VPC 域名,镜像专用,免流量)
3. 🥉 **`mirrors.aliyun.com`**(公网,走 SLB,有流量费但 HTTPS)
4. ❌ 上游官方源(慢、可能不通)

## 一键脚本

仓库内已有的:

- [centos/switch-aliyun-mirror.sh](centos/switch-aliyun-mirror.sh) — CentOS yum 一键换阿里源
- [centos/nexusify.sh](centos/nexusify.sh) — yum 走 Nexus(优先级更高)
- [docker/install.sh](docker/install.sh)(get.docker.com 副本)+ `--mirror Aliyun` 参数

## 检查源连通性

```bash
# 一行验证 4 大常用源
for u in \
  https://mirrors.aliyun.com/pypi/simple/ \
  https://mirrors.aliyun.com/pytorch-wheels/cu121/ \
  https://mirrors.aliyun.com/centos/ \
  https://maven.aliyun.com/repository/public/ ; do
  printf "  %s  → " "$u"
  curl -sI -o /dev/null -w "%{http_code}\n" --max-time 5 "$u"
done
# 全部期望 200 / 301 / 302
```
