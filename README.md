# Linux Ops Notes

> 面向 Linux、容器与云原生运维的实践知识库：记录真实场景中的部署配置、Shell 脚本、排障经验与技术选型，帮助读者更快找到可参考的方案，并把重复工作逐步标准化。

## 这个仓库解决什么问题？

运维工作经常遇到相似的问题：环境搭建步骤散落在笔记中、部署命令难以复用、故障处理依赖个人经验，修改配置后也缺少一致的验证流程。

本仓库把 Linux 系统管理、Docker/containerd、Kubernetes、网络、数据库、监控与 CI/CD 等实践资料集中归档，方便**查找、理解、复用和持续改进**。它是运维知识库和配置参考集，**不是开箱即用的统一部署平台**。

## 能带来什么价值？

| 价值 | 对应的使用方式 |
|---|---|
| 减少重复劳动 | 参考已有脚本、配置模板和部署步骤，而不是每次从零开始 |
| 缩短排障路径 | 从相关模块的操作记录、验证命令和故障经验入手 |
| 降低学习门槛 | 对照实际配置理解 Linux、容器、Kubernetes 等技术 |
| 促进操作标准化 | 把环境检查、变更、验证、回滚与复盘整理成可复用流程 |
| 保留经验上下文 | 通过 Git 记录文档和配置变更，便于追踪与维护 |

以上是仓库的**用途和建设目标**，并不意味着每份脚本都经过完整功能测试；具体可信程度以各模块的状态标记和验证说明为准。

## 怎么使用？

按目标选择入口，而不是从头浏览所有目录：

| 你的目标 | 推荐入口 |
|---|---|
| 学习 Linux 系统管理与自动化 | [centos/](centos/README.md)、[ansible/](ansible/README.md) |
| 安装容器运行时或编排服务 | [docker/](docker/README.md)、[containerd](docker/containerd/readme.md) |
| 部署或维护 Kubernetes 集群 | [kubernetes/](kubernetes/README.md) |
| 排查网络、入口和代理问题 | [network/](network/)、[nginx/](nginx/README.md)、[Kubernetes 网络](kubernetes/README.md) |
| 维护数据库、监控或 CI/CD | [mysql/](mysql/README.md)、[redis/](redis/README.md)、[监控](kubernetes/prometheus/README.md)、[devops/](devops/README.md) |

**推荐操作顺序：**

1. **定位**：通过上表或下方目录索引找到模块，阅读对应 README 和操作说明。
2. **确认**：核对系统版本、集群环境、依赖、路径、域名及配置中的占位符。
3. **评估**：识别删除、覆盖、证书更新、网络切换等高风险动作，准备备份和回滚方案。
4. **验证**：优先在测试环境执行；对脚本先做语法/静态检查，有条件时进行隔离功能测试。
5. **实施与验收**：按步骤操作，并使用健康检查、日志和业务验证确认结果。
6. **沉淀**：记录实际差异、故障原因和改进建议，持续更新文档。

> **安全提醒**：仓库中包含真实环境的配置归档及操作记录。不要未经审查就直接在生产环境执行脚本或复制配置；尤其不要把所有 `.sh` 文件视为可以无条件自动运行的程序。

## 哪些运维流程可以优化？

这个仓库不仅保存“怎么做”，也可以逐步沉淀“如何做得更稳”：

| 常见做法 | 改进方向 |
|---|---|
| 遇到问题临时搜索、临时处理 | 将症状、根因、验证命令和修复步骤整理为可检索的案例 |
| 重复手工执行部署命令 | 对稳定、重复的操作抽取参数化脚本，并保留人工确认点 |
| 修改后直接上线 | 增加变更检查、测试验证、备份与回滚准备 |
| 只检查脚本能否解析 | 分层开展 Bash 语法、ShellCheck、安全审计和隔离功能测试 |
| 部署结束就算完成 | 明确健康检查、验收标准及异常处理方式 |
| 文档与实际操作逐渐脱节 | 在修复问题或变更配置时同步更新相关说明 |

**建议的持续改进闭环：**

`需求 → 查找现有方案 → 风险评估 → 测试 → 实施 → 验收 → 复盘 → 文档与自动化改进`

其中，仓库内的 Shell 脚本应按风险分级：所有适用脚本可做静态检查；普通工具脚本可在临时环境做功能测试；部署、卸载、证书轮换、磁盘及网络变更脚本需要专门的隔离环境。**静态检查通过不等于功能验证通过。**

---

## 目录结构

### 系统管理

| 目录 | 内容 | 状态 |
|---|---|---|
| [ansible/](ansible/README.md) | Ansible 自动化配置（Playbook、ad-hoc 命令） | 验证过 |
| [centos/](centos/README.md) | CentOS 系统管理（安全加固、LVM、内核升级、SSH 防护） | 验证过 |
| [git/](git/README.md) | Git 全局配置及代理设置 | 常用工具 |

### 容器与编排

| 目录 | 内容 | 状态 |
|---|---|---|
| [docker/](docker/README.md) | Docker 生态（安装、镜像构建、docker-compose 服务编排、Kind 测试集群、nvidia-container-toolkit GPU 节点） | ✅ 生产验证 |
| [docker/containerd/](docker/containerd/readme.md) | Containerd 运行时安装与配置（离线部署、K8s 集成） | 验证过 |

### 容器编排平台

| 目录 | 内容 | 状态 |
|---|---|---|
| [kubernetes/](kubernetes/README.md) | Kubernetes 核心（集群部署、网络、存储、监控、CI/CD） | ✅ 生产验证 |
| [kubernetes/k3s/](kubernetes/k3s/README.md) | K3s 轻量级 K8s（边缘计算、IoT） | 验证过 |
| [kubernetes/kubesphere/](kubernetes/kubesphere/README.md) | KubeSphere 容器平台（多集群管理、配置示例） | ✅ 生产验证 |
| [kubernetes/arm-k8s/](kubernetes/arm-k8s/README.md) | ARM 架构 K8s 集群（鲲鹏/飞腾） | 验证过 |

### 网络

| 目录 | 内容 | 状态 |
|---|---|---|
| [nginx/](nginx/README.md) | Nginx 配置（反向代理、SSL/TLS、HTTP-FLV 直播流） | ✅ 生产验证 |
| [dns/](dns/README.md) | BIND9 内网 DNS 服务搭建 | 验证过 |
| [frp/](frp/README.md) | frp 内网穿透（Docker & K8s 部署，TOML 配置） | ✅ 生产验证 |
| [nps/](nps/README.md) | nps 内网穿透 | ✅ 生产验证 |
| [network/](network/) | mihomo 代理（裸核 + TUN，跑在 node02 systemd），取代 clash | ✅ 生产验证 |
| [clash/](clash/README.md) | Clash 代理客户端（🟡 已弃用，见 [network/mihomo/](network/mihomo/)） | 历史归档 |
| [kubernetes/istio/](kubernetes/istio/README.md) | Istio 服务网格（跨 Namespace 通信） | 验证过 |

### 存储

| 目录 | 内容 | 状态 |
|---|---|---|
| [minio/](minio/README.md) | MinIO 对象存储（Docker Compose、跨集群同步） | ✅ 生产验证 |
| [kubernetes/etcd/](kubernetes/etcd/README.md) | etcd 集群部署（Docker Compose、反向代理、备份） | ✅ 生产验证 |

### 数据库

| 目录 | 内容 | 状态 |
|---|---|---|
| [mysql/](mysql/README.md) | MySQL 运维（InnoDB Cluster、Router、备份、K8s CronJob、[容量规划/性能瓶颈速查](mysql/capacity-planning.md)） | ✅ 生产验证 |
| [redis/](redis/README.md) | Redis 通用运维 + [容量规划/性能瓶颈速查](redis/capacity-planning.md)（链路、4 资源轴、Sentinel/Cluster 选型、排障命令） | ✅ 生产参考 |

### 监控

| 目录 | 内容 | 状态 |
|---|---|---|
| [kubernetes/prometheus/](kubernetes/prometheus/README.md) | Prometheus & VictoriaMetrics 监控（部署指南、告警、Grafana） | ✅ 生产验证 |

### CI/CD

| 目录 | 内容 | 状态 |
|---|---|---|
| [devops/](devops/README.md) | CI/CD 流水线（Jenkins、Java/Node.js 项目部署、K8s Pod 模板） | ✅ 生产验证 |

### 工具

| 目录 | 内容 | 状态 |
|---|---|---|
| [aliyun-mirrors.md](aliyun-mirrors.md) | 阿里云镜像源速查（PyPI / PyTorch+CUDA / Conda / yum/apt / ACR / Maven / k8s,公网 vs ECS 内网） | ✅ 生产参考 |
| [kubernetes/k9s/](kubernetes/k9s/README.md) | K9s Kubernetes 终端管理工具 | 常用工具 |
| [ai/go/](ai/go/README.md) | Go 语言笔记（Channel 模式） | 学习笔记 |

### AI

| 目录 | 内容 | 状态 |
|---|---|---|
| [ai/claude-code/](ai/claude-code/bootstrap.cmd) | Claude Code Windows 安装脚本（Nexus 加速） | 验证过 |
| [ai/dify/](ai/dify/deploy.sh) | Dify LLM 应用平台 Docker Compose 一键部署 | 验证过 |
| [ai/nvidia/](ai/nvidia/) | NVIDIA GPU 驱动 + Container Toolkit 安装（走 Nexus 代理） | ✅ 生产验证 |
| [ai/nvidia-container-toolkit/](ai/nvidia-container-toolkit/) | GPU 节点 nvidia-container-toolkit 配置 | ✅ 生产验证 |
| [ai/ollama/](ai/ollama/) | Ollama 本地 LLM 部署 | 验证过 |

> ✅ **生产验证** = 该模块的配置已在生产环境运行使用  
> **验证过** = 在测试/预发环境验证过  
> **学习笔记** = 个人学习记录，仅供参考  
> 🟡 **已弃用** / **历史归档** = 已被新方案取代，仅作历史参考

## 快速指引

| 场景 | 入口 |
|---|---|
| MySQL InnoDB 集群（生产推荐） | [mysql/mysql-config.md](mysql/mysql-config.md) |
| K8s 集群部署 | [kubernetes/README.md](kubernetes/README.md) |
| Prometheus 监控（VictoriaMetrics 生产推荐） | [kubernetes/prometheus/README.md](kubernetes/prometheus/README.md) |
| Jenkins CI/CD 流水线 | [devops/README.md](devops/README.md) |
| Docker 服务编排 | [docker/docker-compose/](docker/docker-compose/) |
| Nginx 反向代理 | [nginx/nginx.cnf](nginx/nginx.cnf) |
| frp 内网穿透 | [frp/README.md](frp/README.md) |
| MinIO 对象存储 | [minio/README.md](minio/README.md) |
| KubeBlocks MySQL operator（K8s HA 部署） | [kubernetes/kubeblocks/mysql/](kubernetes/kubeblocks/mysql/) |
| mihomo 代理（裸核 TUN，生产在跑） | [network/mihomo/](network/mihomo/) |
| GPU 节点 nvidia-container-toolkit（走 Nexus 代理） | [ai/nvidia-container-toolkit/](ai/nvidia-container-toolkit/) |
| Harbor 仓库架构（huball/ghcr/quay/k8s 多前端） | [CLAUDE.md](CLAUDE.md) → "Harbor 架构" 段 |
