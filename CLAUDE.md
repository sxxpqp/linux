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

## 详细参考(按需 Read,不默认加载)

本文件只放每次对话都要用的核心。下面的细节放在 `docs/` 下,**用到时再 Read**:

| 何时需要 | 文件 |
|---|---|
| 配置 Docker / containerd 加速 / 写 Nexus URL / 查 Harbor 项目 / 找阿里 ACR 命名空间 / 历史弃用地址 | [docs/infra-reference.md](docs/infra-reference.md) |
| 写新 `.sh` 脚本(首行三件套、文件名约定、下载链接、脚本/YAML/文档质量标准) | [docs/script-conventions.md](docs/script-conventions.md) |
| 生产事故 / 跨系统排障(8 步范式 + 真实案例) | [docs/troubleshooting-template.md](docs/troubleshooting-template.md) |
| 把仓库经验整理成 MD 发到知乎 / 博客 / 公众号 | [docs/external-publishing.md](docs/external-publishing.md) |

## 共享基础设施 — 核心入口

> **核心原则**:任何要走公网的 URL,优先用自建代理(Harbor / Nexus / 1Panel),实在没有再用阿里 / 清华公共镜像,最后才直连官方源。

| 项 | 值 | 备注 |
|---|---|---|
| **镜像拉取入口(Harbor)** | `dockerhub.ihome.sxxpqp.top:8443` | **纯代理,不接受 push**。其它上游域名见下面"Harbor 架构" |
| **镜像推送目标(阿里 ACR)** | `registry.cn-hangzhou.aliyuncs.com/sxxpqp/` | 自己构建的镜像统一推这里(用户名 `sxxpqp`,杭州区) |
| MinIO S3 API endpoint | `https://ihome.sxxpqp.top:8443` | S3 客户端 / SDK |
| MinIO 控制台 UI | `https://console.ihome.sxxpqp.top:8443` | 管理界面 |
| Nexus 私服(Base) | `https://nexus.ihome.sxxpqp.top:8443` | **非镜像内容**:raw / helm / 二进制包 |
| 个人文件中转(chfs) | `https://chfs.sxxpqp.top:8443/chfs/shared/` | 离线包、ISO、压缩包;HTTP 直接 GET |
| 常用测试主机 | `node02` (192.168.150.253, enp1s0) | network / clash / mihomo |

> 历史弃用地址(`dockerhub.sxxpqp.top` / `harbor.iot.store:8085` / `mirror.ghproxy.com` 等)见 [docs/infra-reference.md](docs/infra-reference.md) "历史 / 弃用"。

### Harbor 架构(关键)

Harbor 后端是同一个,但前面挂了 **1Panel/nginx 多前端域名**,**每个域名内部已经做了路径重写**,所以客户端只需要按上游选对应的域名,不用关心 Harbor 内部的项目前缀。

| 上游 | 对应前端域名(1Panel/nginx) | 后端 Harbor 项目 | nginx 内部 rewrite |
|---|---|---|---|
| `docker.io` | `dockerhub.ihome.sxxpqp.top:8443` | `dockerhub` | `/v2/*` → `/v2/dockerhub/*` |
| `ghcr.io` | `ghcr.ihome.sxxpqp.top:8443` | `ghcr` | `/v2/*` → `/v2/ghcr/*` |
| `quay.io` | `quay.ihome.sxxpqp.top:8443` | `quay` | `/v2/*` → `/v2/quay/*` |
| `registry.k8s.io` / `k8s.gcr.io` | `k8s.ihome.sxxpqp.top:8443` | `google_containers` | `/v2/*` → `/v2/google_containers/*` |

> Docker / containerd `hosts.toml` 完整模板见 [docs/infra-reference.md](docs/infra-reference.md) "Docker / containerd 加速源配置"。

### 推镜像(只推阿里云)

**Harbor 不接受 push**。自己构建的镜像统一推 **阿里云 ACR** 命名空间 `sxxpqp`:

```bash
docker login registry.cn-hangzhou.aliyuncs.com   # 用户名 sxxpqp
docker tag <local> registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
docker push      registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>
```

之后在 K8s yaml 里 `image:` 直接写 `registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>`(国内节点直连阿里云就够快)。

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

## 输出质量要求(资深运维开发工程师标准)

默认按"**生产环境运维开发工程师**"的水准产出,不是"够用就行"。

> 脚本 / K8s YAML / 文档 README 的具体落地标准见 [docs/script-conventions.md](docs/script-conventions.md) "输出质量要求"段。

### 回答风格

- **表态明确**:不该用就直说"不推荐",**不要"也许可以试试"**
- **比较要给依据**:"A 比 B 快 3x" 要给测试方法/来源,凭感觉不写
- **不重复用户已知的**:用户贴了 journalctl,直接基于输出回答,不让用户再跑命令(除非真缺信息)
- **生产文件特别谨慎**:动 `kubernetes/` `devops/` 下标 ✅ 生产的内容前,先确认是否要 dry-run / 备份
- **批量动作前先盘点**:涉及 ≥3 个文件先列清单,给用户刹车的机会
- **commit message 描述"为什么"**:不是 `update xxx`,是 `fix(scope): rationale`
- **错误不要藏**:做错了直接说"我加错了 X 行",分析根因,**不要悄悄打补丁**
- **🔑 输出深度先评估**(下面 4 条质量规则的触发开关) — **默认按问题分级,不每次灌全套**:
  - **L1 简单**(单个命令 / 参数 / 是非题 / 小修改):直接给答案,不画链路不列 trade-off,1-2 段搞定
  - **L2 中等**(排查 / 选型 / 性能 / 配置改造):**动手前先一句话问"要快速答案 + 命令 还是完整链路+根因+对比?"** 等用户拍板再展开
  - **L3 复杂**(生产事故 / 架构决策 / 跨系统排障):走完整 8 步范式,不省;但**沉淀步骤(⑧)** 也要先问"要不要落盘到 capacity-planning.md / bug.md"。完整范式见 [docs/troubleshooting-template.md](docs/troubleshooting-template.md)
  - **判断标准**:涉及生产影响、有多种方案选择、错误链路长 → L2/L3;否则 L1
- **🆕 画出完整链路**(L2/L3 启用):用户问"X 连不通"/"Y 报错",先画完整请求链(`client → ingress → svc → pod → upstream`),标出每层可能故障点 + 对应排查命令,**不要只盯一个症状**
- **🆕 选型必须 trade-off**(L2/L3 启用):推荐方案 A 时,**必须**用对比表列出 B / C 备选 + 给出"为什么不是 B"的具体理由(性能 / 兼容 / 复杂度 / 生态),不能只说"用 A 就行"
- **🆕 根因不止症状**(L2/L3 启用):报错日志只是表象,要追到底层(网络? DNS? 权限? 配置漂移? 内核参数?)。根因没找到不算解决,补丁只是缓解
- **🆕 产出要可复用**(L2/L3 启用):同样的问题第二次出现要能直接抄 —— 把检查/修复步骤封装成函数/脚本/Makefile target,沉淀到对应子目录,**沉淀前先问用户是否需要**,不要让排查路径只活在某次对话里

### 反面案例(本仓库踩过的)

| ✗ 错误做法 | ✓ 正确做法 |
|---|---|
| `curl ... \| bash -s ... </dev/null` | `mktemp + curl -o + bash <file> </dev/null`(`-s` 模式 stdin 抢占冲突) |
| `kubectl create namespace x` | `kubectl create ns x --dry-run=client -o yaml \| kubectl apply -f -` |
| `git add .`(macOS)误以为会带上所有 modified | macOS case-insensitive 下大小写双跟踪文件 `git add` 静默失败,用 `git update-index --add` |
| 改 README 状态字段后没改图例 | 加新状态(🟡 已弃用)同步更新图例段 |
| 顶层目录改名后 README 索引不更新 | 改完目录立刻 grep 一遍 README 看死链 |

## 已知踩坑(跨项目通用)

1. **GitHub raw 直连基本不通**:任何 `raw.githubusercontent.com` 的 URL,优先改成走 Nexus raw 代理。
2. **GitHub release zip 直连基本不通**:同上,或者改用 `chfs.sxxpqp.top` 上预先放好的离线包。
3. **CentOS / RHEL 默认带 firewalld + SELinux**:网络类排障第一步先 `systemctl status firewalld` + `getenforce`。
4. **systemd-resolved**:Ubuntu 系会占 53 端口,跑 DNS 类服务前先 `systemctl status systemd-resolved`。
5. **libvirt virbr0**:测试机上常见的虚拟网桥,跟物理网卡分流时要排除,自动检测出口网卡的程序经常误选它。
6. **macOS case-insensitive 文件系统 + git 大小写双跟踪**:在 Linux 上提交过 `README.md` 和 `readme.md` 两份,macOS 本地 pull 下来只有一个 inode(取决于谁先到),`git add README.md` 静默失败(指向不存在的 SHA)。修法:`git update-index --add <path>` 强行 stage;长期清理 `git rm --cached <小写名>` 保留大写。
7. **`curl <url> \| bash -s args </dev/null` 死锁**:`bash -s` 模式 stdin 是脚本源,`</dev/null` 会抢占管道导致 bash 立即 exit,curl 收 SIGPIPE 报 `curl: (23) Failed writing body`。要切 tty 用 `mktemp + curl -o + bash <file> </dev/null`。完整 8 步分析见 [docs/troubleshooting-template.md](docs/troubleshooting-template.md)。
8. **systemctl 进 less 卡住脚本**:`SYSTEMD_PAGER=` 不够,老 systemd 还读 `PAGER` / `SYSTEMD_LESS`。生产脚本三件套 `export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''` + 每条 `systemctl --no-pager`,子进程切 tty `</dev/null`。

## 不要做的事

- ❌ 不要主动建 README.md / 文档,除非用户明确要求(顶层 README 已经很全)。
- ❌ 不要把生产 IP / 密码 "脱敏",这是用户自己的内网,本来就是真实值。
- ❌ 不要把 yaml 重排序 / 重格式化,只改用户要求改的字段。
- ❌ 不要在不熟悉的子目录大改,先 Read 该子目录 README + 至少一个示例文件再动手。
