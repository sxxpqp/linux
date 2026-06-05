---
name: linux-ops-edit
description: Apply this repo's editing conventions when modifying production configs under kubernetes/, devops/, docker/, network/, or any file marked ✅ 生产验证 in a README. Use whenever editing YAML, Dockerfile, .conf, .sh, install/uninstall scripts, or shell snippets in this knowledge base. Triggers on phrases like 改 yaml, patch 配置, 改生产文件, 改 devops, 改 kubernetes,, 改 calico, 改 nginx, 改 docker-compose, 加 env, 调整副本, 改镜像 tag. Enforces:do NOT reformat YAML, do NOT redact real IPs/passwords, list ≥3 file batches first, prompt before touching ✅生产 files, no auto-create README, use update-index for case-insensitive filename dupes.
---

# 本仓库编辑约定

> **核心**:这不是一个"代码项目",是个人运维知识库 + **生产环境真实配置归档**。改文件 ≠ 改生产,但很多 IP / 密码 / 订阅 URL 是真实值,**修改门槛比写代码高**。

## 改之前必须做的 3 件事

### 1. 判断是不是生产文件

```bash
# 读对应子目录 README,看状态标记
# ✅ 生产验证   = 生产在跑,改前必确认 / 备份
# 验证过      = 测试过,改起来谨慎些
# 学习笔记    = 随便改
```

子目录优先级见根 `CLAUDE.md` "子目录优先级 / 当前活跃区域"段:
- `network/mihomo/`、`kubernetes/`、`docker/docker-compose/`、`devops/` 是活跃区
- `devops/` 下还有多集群版本(`saas / sd / tsl / tzj / whrr / ztwx / huawei-saas / gstest`),改一个不一定能套到另一个 — **先问对方需要哪个集群**

### 2. 批量动作先列清单

涉及 **≥3 个文件** 的改动,先用 Grep / Glob 列清单给用户确认,**给刹车的机会**:

```bash
# 例:要把所有 calico 镜像 tag 从 v3.28.2 升到 v3.29.0
grep -rl "v3.28.2" kubernetes/calico/  # 先列
# 用户 OK 后再批量改
```

### 3. ✅ 生产标记文件:先备份提示

```
我看 kubernetes/calico/onpremises/operator/install.sh 是 ✅ 生产验证,
要不要先 cp 一份 .bak 再改?或者你确认直接改也行。
```

## 编辑规则(硬性)

| 规则 | 为什么 |
|---|---|
| **不重排序 / 不重格式化 YAML / JSON** | 这些是从服务器拉回来的原始配置,顺序有意义。只动用户要求改的字段 |
| **不脱敏 IP / 密码 / 订阅 URL** | 用户自己的内网,本来就是真实值,脱敏反而丢信息 |
| **不主动建 README.md** | 顶层 README 已经很全,不需要补 |
| **改 K8s namespace 时**:用 `kubectl create ns x --dry-run=client -o yaml \| kubectl apply -f -` | 而非 `kubectl create ns x`,后者不幂等 |
| **改完目录立刻 `grep` 一遍根 README** | 看有没有死链 |
| **加新状态(如 🟡 已弃用)同步更新图例段** | README 顶部图例段要跟正文一致 |

## macOS 大小写敏感踩坑

如果用户在 macOS 上 pull 这个 Linux 仓库:**case-insensitive 文件系统**会让 `README.md` 和 `readme.md` 这种双跟踪文件只能存一份(inode 复用)。

```bash
# 现象:git status 显示 modified 但 git add 静默失败
# 修法:
git update-index --add <path>        # 强行 stage 不存在的引用
git rm --cached <小写名>             # 长期清理,保留大写
```

## 项目特有 shell 脚本规范

任何新写的 `.sh` 都要满足:

```bash
#!/usr/bin/env bash
# 系统: <从哪个系统跑 / 对哪个系统操作>
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/<path>
# 用法: curl -sL <URL> -o xxx.sh && bash xxx.sh [选项]

set -euo pipefail

# 防 systemctl 进 pager 卡住(老 systemd 还读 PAGER / SYSTEMD_LESS)
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''
```

完整脚本质量标准、`curl | bash` 死锁、`mktemp + bash <file> </dev/null` 模式见 `docs/script-conventions.md`。

## 提交流程

**修改完直接 push,不询问**(用户偏好,见 CLAUDE.md "对话风格偏好"):

```bash
bash gitpush.sh "<scope>: <做了什么>"
```

commit message 格式:
- `fix(calico/operator): 修 xxx`
- `feat(devops/saas): 加 xxx`
- `refactor(network/mihomo): 重构 xxx`
- `docs(claude-md): 拆 xxx`

**只在 delete / move / 覆盖类操作前问一句**:`rm` / `mv` / `git rm` / `kubectl delete` 重要资源 / 整表 `iptables-restore` / `truncate`。

## 危险操作清单(必须问)

| 操作 | 为什么需要确认 |
|---|---|
| `rm -rf <生产目录>` | 不可逆 |
| `mv <生产文件>` 改名 / 跨目录 | 引用会断 |
| `kubectl delete ns/pv/storageclass` | 数据 / 持久卷会丢 |
| `iptables-save \| ... \| iptables-restore` | 整表替换,易误伤其它规则 |
| 改 `gitpush.sh`(用户提交入口) | 全仓提交流程依赖 |
| 删除 `docs/*.md` | 这是 CLAUDE.md 按需加载的索引 |

## 反模式

| ✗ | ✓ |
|---|---|
| `kubectl create namespace x` | `kubectl create ns x --dry-run=client -o yaml \| kubectl apply -f -` |
| 把生产 IP 改成 `<your-ip>` 脱敏 | 保留真实值 |
| `yq -i 'sort_keys(.spec.template.spec.containers[0].env)'` 重排 yaml | 只 `sed -i` 改用户要求的那一行 |
| 在不熟悉的子目录大改 | 先 Read 子目录 README + 至少 1 个示例文件再动手 |
| `git add .`(macOS) | 大小写双跟踪文件会静默失败,用 `git update-index --add` |
| 自动建 README.md / 文档 | 不主动写文档,除非用户明确要 |
| commit message: `update xxx` | `fix(scope): rationale` —— 说清楚"为什么" |

## 何时调用此 skill

- 用户说要 "改 yaml" / "改 patch" / "改 image" / "调副本数" / "改 env" / "改 calico" / "改 nginx 配置" / "改 docker-compose"
- 编辑 `kubernetes/` / `devops/` / `docker/` / `network/` / `clash/` 下任何文件
- 用户问"这个文件能改吗"、"改完要不要重启"、"改完怎么推到生产"
- 新写 `.sh` 安装 / 卸载脚本(配套 `docs/script-conventions.md`)
- 涉及多集群版本(saas / sd / tsl 等)中的配置同步
