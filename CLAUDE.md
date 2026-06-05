# Linux Ops Notes — AI 协作上下文

> 项目: https://github.com/sxxpqp/linux
> 这是给 Claude 看的。人类索引见 [README.md](README.md)。
> 任何关于本仓库的对话,先读这里,再读对应子目录的 CLAUDE.md / README.md。

## 仓库性质(重要)

- **这是一个个人运维知识库 / 配置实物归档**,不是某一个可运行的应用项目。
- 多数 `.md` 是操作记录、踩坑笔记;多数 `.yaml` / `.conf` / `Dockerfile` 是**生产或测试环境真实在跑的配置**,从服务器同步回来归档。
- 因此:
  - **改这里的文件 ≠ 改生产**。要落到生产,需要 `scp` / `ansible` / `git pull` 推上去再重启服务。
  - 文件里的 IP、域名、密码、订阅 URL 大多是**真实**的,改的时候要小心。
  - 不要在本仓库里"重构代码" —— 这些不是代码,是参考实现。除非明确要求,否则只做**就地修订**。

## 详细参考(按需加载,不默认占 context)

| 何时需要 | 在哪 |
|---|---|
| **写或改任何脚本前**:K8s/Shell/iptables/网络类脚本踩坑清单 | **skill: script-pitfalls**(自动触发) |
| **写或改 K8s yaml**:Deployment/Service/Ingress/HPA/CronJob 等生产模板 + 反模式 | **skill: k8s-yaml-prod**(自动触发) |
| 公网 URL 改写成自建代理(Harbor / Nexus / chfs / 阿里 ACR) | **skill: infra-url-rewrite**(自动触发) |
| K8s 资源卡 Terminating / RBAC 残留 / webhook 拦 API | **skill: k8s-cleanup-stuck**(自动触发) |
| 改 yaml / patch 生产配置 / 改 devops 文件 | **skill: linux-ops-edit**(自动触发) |
| 完整 Harbor / Nexus URL 表 + 历史弃用地址 + Docker hosts.toml 模板 | [docs/infra-reference.md](docs/infra-reference.md) |
| 写新 `.sh` 脚本(首行三件套、文件名约定、质量标准) | [docs/script-conventions.md](docs/script-conventions.md) |
| 生产事故 / 跨系统排障(8 步范式 + 真实案例) | [docs/troubleshooting-template.md](docs/troubleshooting-template.md) |
| 把仓库经验整理成 MD 发到知乎 / 博客 / 公众号 | [docs/external-publishing.md](docs/external-publishing.md) |

## 共享基础设施 — 核心入口(每次都要用)

> **核心原则**:任何要走公网的 URL,优先用自建代理。完整改写规则见 `infra-url-rewrite` skill。

| 项 | 值 |
|---|---|
| **镜像拉取入口(Harbor)** | `dockerhub.ihome.sxxpqp.top:8443`(纯代理,不接受 push) |
| **镜像推送目标(阿里 ACR)** | `registry.cn-hangzhou.aliyuncs.com/sxxpqp/` |
| MinIO S3 API | `https://ihome.sxxpqp.top:8443` |
| Nexus 私服(raw / helm / 二进制) | `https://nexus.ihome.sxxpqp.top:8443` |
| 个人文件中转(chfs) | `https://chfs.sxxpqp.top:8443/chfs/shared/` |
| 常用测试主机 | `node02` (192.168.150.253, enp1s0) |
| **测试集群** | kh(172.16.150.128), node1-4(172.16.150.129-131), Pod CIDR=10.244.0.0/16 |
| **测试集群 BGP 参数** | AS=64500, LB CIDR=172.16.150.200/29, 路由器 peer=172.16.150.131:64500 |

> Harbor 多前端域名(`ghcr.ihome` / `quay.ihome` / `k8s.ihome`)+ 内部 rewrite 规则 + 推镜像命令 → 见 skill `infra-url-rewrite`。

## 子目录优先级 / 当前活跃区域

| 子目录 | 用途 | 是否有 CLAUDE.md / README |
|---|---|---|
| `kubernetes/` | **K8s 全栈**, 先读 [kubernetes/README.md](kubernetes/README.md) 定位 | ✅ README(含完整索引) |
| `kubernetes/calico/` | Calico CNI(BPF / BGP / BGP-LB 三模式) | ✅ 每个子目录有 README |
| `kubernetes/calico/bgp-lb/` | **生产推荐**: BGP + 内置 LB + 自动分配 | ✅ README + deploy-guide |
| `kubernetes/ingress-nginx/` | 入口: DS+hostNetwork, 安装/卸载/验证 | ✅ README |
| `kubernetes/metallb/` | MetalLB(L2 + BGP), 可被 Calico BGP-LB 替代 | ✅ README |
| `network/mihomo/` | mihomo 代理(裸核 + TUN,跑在 node02) | ✅ 有专用 |
| `docker/` | docker-compose 模板 + nerdctl 安装 | 无 |
| `devops/` | Jenkins 流水线 + Pod 模板(多集群) | 无 |
| `clash/` | clash 配置(已被 mihomo 取代) | 无 |
| `docker/docker-compose/` | docker-compose 服务模板(mysql / nginx / redis 等) | 无 |
| `devops/` | Jenkins 流水线 + 各业务 K8s Pod 模板(多集群:saas / sd / test / tsl / tzj / whrr / ztwx / huawei-saas 等) | 无 |

需要在某个子目录建立独立上下文时,在那里加一份 CLAUDE.md(参考 `network/mihomo/CLAUDE.md`)。

## K8s 常见操作入口(自动加载对应 README)

| 操作 | 入口脚本/文档 |
|---|---|
| 装 Calico BPF | `bash kubernetes/calico/onpremises/operator/install.sh --apiserver-host=<IP> --delete-kube-proxy` |
| 装 Calico BGP-LB | `bash kubernetes/calico/bgp-lb/install.sh --apiserver-host=<IP> --my-asn=64500 --lb-cidr=<CIDR>` |
| 装 ingress-nginx | `bash kubernetes/ingress-nginx/install.sh --label-nodes=n1,n2` |
| 装 MetalLB | `bash kubernetes/metallb/install.sh` |
| 验证网络 | `bash kubernetes/calico/test-connectivity.sh` |
| 验证 ingress | `bash kubernetes/ingress-nginx/test.sh` |
| Calico BPF→BGP 迁移 | `bash kubernetes/calico/switch-to-bgp.sh --my-asn=64500 --peer-asn=64501 --peer-address=<IP>` |

> **读我顺序**: 用户提到某个目录 → 先 `Read` 该目录的 README.md → 再看具体脚本/文件。

## 跨项目约定

1. **每个一级子目录都有自己的 README.md** —— 被问到某个主题时,先 Read 对应 README。
2. **状态标记**(README.md 里有):`✅ 生产验证` / `验证过` / `学习笔记`。改生产验证类的文件要更谨慎。
3. **同一项目可能有多个集群版本**(尤其 devops/ 下):`saas / sd / tsl / tzj / whrr / ztwx / huawei-saas / gstest` 是不同客户/环境,改一个不一定能套到另一个,**先确认对方需要的是哪个集群**。
4. **同步脚本** `gitpush.sh` 在顶层 —— 不要随便改,这是用户提交笔记到远端的入口。

## 对话风格偏好

- 用户用中文沟通,但命令、日志、变量名保留英文。
- 回答**先给结论 + 直接可执行的命令**,再补原理 / 排查路径。
- 用户喜欢 **表格 + 代码块 + 分点** 的结构,排版清晰比文字密度更重要。
- 用户会贴 `journalctl` / `ip route` / `systemctl status` 的原始输出 —— 直接基于输出回答,不要让用户"再跑一遍 X 命令"除非真的缺信息。
- 修改配置文件时:**优先用 Edit 工具改本地文件**,然后告诉用户 `scp` / `git push` 推到服务器的命令,不要只在回复里贴 diff。
- **执行命令不需要询问**(包括 git push / kubectl apply / 启动服务等),修改完直接 push,commit message 自拟(格式:`bash gitpush.sh "<message>"`)。
- **只有删除 / 移动 / 覆盖类操作才需要确认**:`rm` / `mv` / `git rm` / `kubectl delete` 重要资源 / 整表 `iptables-restore` / `truncate` 这些动作前问一句,其它都直接做。

## 输出质量要求(资深运维开发工程师标准)

默认按"**生产环境运维开发工程师**"的水准产出,不是"够用就行"。

### 回答风格

- **表态明确**:不该用就直说"不推荐",**不要"也许可以试试"**
- **比较要给依据**:"A 比 B 快 3x" 要给测试方法/来源,凭感觉不写
- **不重复用户已知的**:用户贴了 journalctl,直接基于输出回答
- **生产文件特别谨慎**:动 `kubernetes/` `devops/` 下标 ✅ 生产的内容前,先确认是否要 dry-run / 备份
- **批量动作前先盘点**:涉及 ≥3 个文件先列清单,给用户刹车的机会
- **commit message 描述"为什么"**:不是 `update xxx`,是 `fix(scope): rationale`
- **错误不要藏**:做错了直接说"我加错了 X 行",分析根因,**不要悄悄打补丁**

### 输出深度先评估(默认按问题分级,不每次灌全套)

- **L1 简单**(单个命令 / 参数 / 是非题 / 小修改):直接给答案,不画链路不列 trade-off,1-2 段搞定
- **L2 中等**(排查 / 选型 / 性能 / 配置改造):**动手前先一句话问"要快速答案 + 命令 还是完整链路+根因+对比?"** 等用户拍板再展开
- **L3 复杂**(生产事故 / 架构决策 / 跨系统排障):走完整 8 步范式;**沉淀步骤(⑧)** 也要先问"要不要落盘到 capacity-planning.md / bug.md"。完整范式见 [docs/troubleshooting-template.md](docs/troubleshooting-template.md)
- **判断标准**:涉及生产影响、有多种方案选择、错误链路长 → L2/L3;否则 L1

### L2/L3 启用的 4 条规则

1. **画完整链路**:用户问"X 连不通"/"Y 报错",先画 `client → ingress → svc → pod → upstream`,标出每层故障点 + 排查命令,**不要只盯一个症状**
2. **选型必须 trade-off**:推荐方案 A 时,**必须**对比表列出 B / C 备选 + 给出"为什么不是 B"的具体理由(性能 / 兼容 / 复杂度 / 生态)
3. **根因不止症状**:报错日志只是表象,要追到底层(网络? DNS? 权限? 配置漂移? 内核参数?)。根因没找到不算解决,补丁只是缓解
4. **产出要可复用**:同样的问题第二次出现要能直接抄 —— 把检查/修复步骤封装成函数/脚本/Makefile target,沉淀到对应子目录,**沉淀前先问用户是否需要**

## 已知踩坑(每次都要 top-of-mind)

- **公网拉取常失败**:GitHub raw / release zip / docker hub 直连基本不通 → 永远走自建代理(`infra-url-rewrite` skill 自动改写)
- **CentOS / RHEL 网络排障**:第一步先 `systemctl status firewalld` + `getenforce`(默认带 firewalld + SELinux)
- **Ubuntu DNS 端口**:跑 DNS 类服务前先 `systemctl status systemd-resolved`(占 53)
- **libvirt virbr0**:测试机常见虚拟网桥,自动检测出口网卡的程序经常误选,跟物理网卡分流时要排除
- **macOS git 大小写**:Linux 上 `README.md` + `readme.md` 双跟踪,macOS pull 下来只剩一个,`git add` 静默失败 → 用 `git update-index --add` 强行 stage(`linux-ops-edit` skill 详述)
- **`curl … | bash` 死锁 / systemctl 进 pager**:都属于"非交互脚本被卡住"类,见 [docs/troubleshooting-template.md](docs/troubleshooting-template.md) + [docs/script-conventions.md](docs/script-conventions.md)

## 不要做的事

- ❌ 不要主动建 README.md / 文档,除非用户明确要求(顶层 README 已经很全)
- ❌ 不要把生产 IP / 密码 "脱敏",这是用户自己的内网,本来就是真实值
- ❌ 不要把 yaml 重排序 / 重格式化,只改用户要求改的字段
- ❌ 不要在不熟悉的子目录大改,先 Read 该子目录 README + 至少一个示例文件再动手
