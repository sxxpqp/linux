# 脚本与配置约定

> 写新 `.sh` / Kubernetes YAML / README 时按这份对齐。`CLAUDE.md` 顶部索引指向这里。

## 文件 / 脚本存放约定

| 类型 | 存放位置 | 拉取方式 |
|---|---|---|
| **脚本**(`.sh` / `.yaml` / `.conf` / 配置模板) | **git 仓库**(本仓库,公开 repo) | Nexus raw-githubusercontent 代理 GitHub,URL 形如 `<nexus>/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/<path>` |
| **大文件**(离线包、ISO、压缩包、二进制) | **chfs 或 MinIO** | chfs 走 HTTP 直拉;MinIO 走 S3 API |
| **镜像** | **Harbor**(代理) / 阿里 ACR(推送) | 见 CLAUDE.md "Harbor 架构" |
| **Helm chart** / GitHub release 二进制 | Nexus 代理 | 见 [infra-reference.md](infra-reference.md) "Nexus 仓库映射" |

**好处**:脚本改了 push 一次 git,新机器执行立即拿到最新版,**不用再手动同步到 chfs**。

**反面案例**:不要把脚本同时维护两份(git + chfs),否则不知不觉就漂移了。

## 脚本首行注释约定

每个 `.sh` 文件必须在其**首行注释块**中包含以下三个标记:

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

## 文件名约定

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

## 下载链接约定

每个 `.sh` 文件必须在首行注释块中包含通过 Nexus 下载的 URL:

```bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/<path>
# 用法: curl -sL <URL> | bash
```

这样在 GitHub 不通的环境下,直接 `curl -sL <Nexus URL> | bash` 就能执行,**无需 git clone**,也无需再记路径。

---

## 输出质量要求 — 脚本(`.sh`)

| 要求 | 落地做法 |
|---|---|
| **强 fail-fast** | `set -euo pipefail`(三件套:errexit / nounset / pipefail),关键允许失败处显式 `\|\| true` |
| **首行三件套** | `# 系统:` + `# 下载:` + `# 用法:`(详见上方"脚本首行注释约定") |
| **参数校验** | 必填缺失 → exit 1 + 用法提示;数值参数(replicas / port / size)校验范围、奇偶、最小值 |
| **幂等** | `kubectl create ns --dry-run=client -o yaml \| kubectl apply -f -` 而不是裸 create;SQL 用 `CREATE USER IF NOT EXISTS`;目录已存在跳过下载 |
| **进度可观测** | 每个阶段 `echo "[i/N] xxx..."` + `✓` / `✗` 标识,失败时直接附排查命令(`journalctl -u xxx` / `kubectl describe`) |
| **可重入** | 第二次跑不破坏第一次结果(`if [ -d ... ]; then warn "跳过"; return; fi`) |
| **临时文件** | `mktemp` + `trap "rm -f $TMP" EXIT`,或显式 `rm -f` 在路径明确处 |
| **破坏性动作三档** | `--dry-run`(预演) + `--force`(剥 finalizer 强清) + `--keep-data`(保 PVC) |
| **pipe / stdin 不抢占** | `curl \| bash -s` 模式下 stdin 是脚本源,**不能再 `</dev/null`**;要切 tty 用 `mktemp + curl -o + bash <file> </dev/null` |
| **systemctl 防 pager** | `export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''` + `systemctl --no-pager`(老 systemd 不读环境变量) |

## 输出质量要求 — Kubernetes YAML

| 要求 | 落地做法 |
|---|---|
| **显式 namespace** | `metadata.namespace` 必填,不依赖当时 kubectl 上下文 |
| **资源声明** | `requests` + `limits` 都给,测试可以小**不能不写** |
| **反亲和** | 副本 ≥3 至少 `preferredDuringScheduling` 跨节点;Paxos/Raft 类强一致系统注释里建议生产用 `required` |
| **可观察** | liveness / readiness / startup 探针;关键服务有 ServiceMonitor |
| **优雅** | `terminationGracePeriodSeconds` + `preStop`;滚动更新策略明确 |
| **安全** | `securityContext.runAsNonRoot` / `readOnlyRootFilesystem` 能开就开 |
| **terminationPolicy** | KubeBlocks Cluster 生产用 `DoNotTerminate`,测试用 `Delete`,**别用 WipeOut 除非你知道在干嘛** |

## 输出质量要求 — 文档 / README

| 要求 | 落地做法 |
|---|---|
| **先结论后细节** | 顶部一句话讲完用途;表格列字段;再展开原理 |
| **决策依据** | 给方案 A / B 对比表(不是只列 A),写"为什么选 A 不选 B" |
| **跨链接** | 相关方案互链(`见 ../mysql/` / `详见 CLAUDE.md "Harbor 架构"`) |
| **状态标注** | ✅ 生产验证 / 🟡 实验 / 🔴 已弃用,跟 README 图例对齐 |
| **可执行示例** | 完整可复制粘贴的命令,不只是描述步骤 |
| **踩坑回写** | 出过的问题写到 `bug.md` 或 CLAUDE.md "已知踩坑"段 |
