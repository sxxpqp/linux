---
name: script-pitfalls
description: Living catalog of script bugs and antipatterns hit in this repo — kubectl delete hangs, finalizer order, operator-managed RBAC, admission webhook residuals, iptables-restore footguns, curl | bash deadlocks, systemctl pager traps. Use BEFORE writing or modifying any install.sh / uninstall.sh / Dockerfile / shell automation script in this repo, AND when an existing script hangs/fails/produces unexpected results. Triggers on: 写脚本, 写 install, 写 uninstall, 改脚本, debug 脚本, 脚本卡住, 脚本不工作, kubectl delete 卡, 卸载脚本翻车, 脚本超时, bash script bug, shell pitfall, script antipattern. CONSULT THIS BEFORE WRITING — every bug here was painful to discover the first time.
---

# 脚本踩坑清单(本仓库踩过的)

> 项目: https://github.com/sxxpqp/linux
> **使用方式**:写新脚本之前 grep 一遍这里有没有相关条目;写完跑前再过一遍"通用检查清单"。每个条目都是真实付出代价学来的,不要再交一次学费。

## 通用检查清单(每次写脚本都过一遍)

写完一个 `.sh` 跑之前问自己:

- [ ] 首行三件套有没有?`set -euo pipefail` + `export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''`
- [ ] 涉及 `kubectl delete` 的资源:有没有 finalizer 可能?**默认先剥再删**
- [ ] 涉及 `curl ... | bash`:有没有可能进 stdin 抢占死锁?(见条目 #shell-1)
- [ ] 涉及 `systemctl`:有没有进 pager 风险?每条命令加 `--no-pager`
- [ ] 涉及 `iptables-save | ... | iptables-restore`:**不要做**(见条目 #net-1)
- [ ] 涉及 operator 类资源(Calico / Cilium / cert-manager):删除顺序对不对?(见 #k8s-2)
- [ ] 涉及 webhook 类资源:操作前 backend 是否还活着?(见 #k8s-4)
- [ ] 有没有自动化检测前置条件失败(Terminating / 残留 RBAC / 残留 webhook)就 exit 1?

---

## K8s 操作类

### #k8s-1 `kubectl delete` 不剥 finalizer 直接删 → 卡 60s+ 超时

**症状**:`kubectl delete <CR/ns>` 没反应,等到 timeout 才报错;或返回 "X deleted" 但 `kubectl get` 还在。

**根因**:K8s 资源有 finalizer 时,delete 只是标记 `deletionTimestamp`,等待 controller 来清除 finalizer。controller 死了 / 卡了 / 被你顺手删了 → 永远等不到。

**错的**:
```bash
kubectl delete installation default --timeout=120s   # 干等 120s 超时
```

**对的**(默认先剥再删,不门控 --force):
```bash
kubectl patch installation default --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null
kubectl delete installation default --ignore-not-found --timeout=30s
```

**为什么不门控 --force**:卸载语义就是"我要它没",finalizer 没人清的概率高,默认就该 strip。`--force` 应该用在比这更激进的场景(剥 ns finalizer 等)。

---

### #k8s-2 operator 类删除顺序错 → RBAC 边删边重建

**症状**:删完 ClusterRole/ClusterRoleBinding,`kubectl get` 一查还在,而且 `creationTimestamp` 没变。

**根因**:operator pod 还活着,在 reconcile 中**重建**了被你删的 RBAC。timestamp 不变是因为 server-side apply 保留原值。

**错的顺序**:
```bash
kubectl delete installation default        # 删 CR
kubectl delete clusterrole calico-node     # ← operator 还在,会立刻重建
kubectl delete -f tigera-operator.yaml     # 最后才删 operator
```

**对的顺序**:
```bash
kubectl patch installation default --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl delete installation default
kubectl -n tigera-operator scale deploy tigera-operator --replicas=0   # ① 先按住 operator
kubectl delete -f tigera-operator.yaml --timeout=180s                   # ② 再删 operator yaml
kubectl delete clusterrole,clusterrolebinding calico-node calico-cni-plugin calico-kube-controllers --wait=false   # ③ 最后清孤儿 RBAC
```

**口诀**:**先关 controller,再清它管的东西**。

---

### #k8s-3 operator yaml 里第一个是 Namespace,后续 cm 删除变无意义

**症状**:`kubectl delete -f tigera-operator.yaml` 之后跑 `kubectl -n tigera-operator delete cm xxx`,显示 "not found" 但你以为是删了。

**根因**:`tigera-operator.yaml` 第一个对象就是 `kind: Namespace`,kubectl 按 yaml 顺序删,ns 一删,里面所有 cm/deploy/sa 跟着没。

**错的**:
```bash
kubectl delete -f tigera-operator.yaml
kubectl -n tigera-operator delete cm kubernetes-services-endpoint    # ← ns 已经没了
```

**对的**(在 ns 还活着时删 cm):
```bash
kubectl -n tigera-operator delete cm kubernetes-services-endpoint --ignore-not-found   # ① 先删 cm
kubectl delete -f tigera-operator.yaml --timeout=180s                                  # ② 再删 yaml
```

---

### #k8s-4 残留 admission webhook → 后续 API 调用静默失败

**症状**:`kubectl delete` 返回 "X deleted",但 `kubectl get` 资源还在;或装其它东西时报错奇怪。

**根因**:`tigera-operator.yaml` / `cilium.yaml` 等里有 ValidatingWebhook / MutatingWebhook,backend service 死了(operator 删了 / Pod 没起来),webhook 配置还在,会拦后续 admission。kubectl 显示成功但 API 实际拒绝。

**怎么检测**:
```bash
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -iE 'calico|tigera|operator'
```

**怎么清**:
```bash
kubectl get validatingwebhookconfigurations -o name | grep -iE 'calico|tigera|operator' | xargs -r kubectl delete --wait=false
kubectl get mutatingwebhookconfigurations -o name | grep -iE 'calico|tigera|operator' | xargs -r kubectl delete --wait=false
```

**写脚本时**:卸载脚本里一定要带 webhook 清理,放在 `delete -f operator.yaml` **之前**。重装脚本的 preflight 必须检测残留 webhook 并 exit 1。

---

### #k8s-5 `kubectl delete --wait=true`(默认)删 RBAC 偶尔卡

**症状**:`kubectl delete clusterrole xxx yyy zzz` 部分输出 "deleted",剩下一个挂在那不返回。

**根因**:kubectl delete 默认 `--wait=true`,等 watch event 确认资源真的从 etcd 消失。API server 慢 / 网络抖动 / 偶发卡 watch。

**修法**:RBAC 删除加 `--wait=false`(纯 API call,不需要等 watch):
```bash
kubectl delete clusterrole calico-kube-controllers calico-node calico-cni-plugin \
  --ignore-not-found --wait=false
```

---

### #k8s-6 在 Terminating 资源上重装 → zombie 状态

**症状**:卸载没等干净就重装,`kubectl apply` 输出 `installation.operator.tigera.io/default configured`(不是 `created`),后续 RBAC 不会被正常重建,Pod 起来报 RBAC forbidden。

**根因**:apply 一个正在 Terminating 的资源,API server 接受 patch 但不会推动 controller 重新初始化。这资源既不死也不活。

**对的做法**:install 脚本的 preflight 必须检测:
```bash
for cr in installation apiserver; do
  if kubectl get $cr default -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
    err "$cr/default 正在 Terminating,先彻底清干净再装"; exit 1
  fi
done
for ns in calico-system tigera-operator calico-apiserver; do
  if kubectl get ns $ns -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; then
    err "ns/$ns Terminating,先剥 finalizer"; exit 1
  fi
done
```

---

### #k8s-7 operator 模式查 dataplane 看错字段

**症状**:Calico operator 装完,脚本验证 `FelixConfiguration.spec.bpfEnabled` 是 `false`,以为 BPF 没起来,但其实在跑(`calico-node -bpf conntrack dump` 有数据)。

**根因**:operator 模式的权威源是 `Installation.spec.calicoNetwork.linuxDataplane`,不是 `FelixConfiguration.bpfEnabled`。operator 不一定显式同步到 Felix CR。

**对的检查**:
```bash
# ① CR 配置
kubectl get installation default -o jsonpath='{.spec.calicoNetwork.linuxDataplane}'   # 期望:BPF
# ② 实测(BPF 真在跑就有 conntrack 数据)
kubectl -n calico-system exec ds/calico-node -- calico-node -bpf conntrack dump | head
```

---

## Shell / Bash 类

### #shell-1 `curl <url> | bash -s args </dev/null` 死锁

**症状**:`curl: (23) Failed writing body`,bash 立即 exit,脚本没跑。

**根因**:`bash -s` 模式 stdin 是脚本源,`</dev/null` 抢占管道,bash 立即收到 EOF exit,curl 收 SIGPIPE。

**错的**:
```bash
curl -sL https://example.com/install.sh | bash -s -- --apply </dev/null
```

**对的**(`mktemp` + 分两步):
```bash
TMP=$(mktemp /tmp/install.XXXXXX.sh)
trap "rm -f $TMP" EXIT
curl -fsSLk https://example.com/install.sh -o "$TMP"
bash "$TMP" --apply </dev/null
```

完整 8 步分析见 [docs/troubleshooting-template.md](../../../docs/troubleshooting-template.md)。

---

### #shell-2 systemctl 进 less 卡住脚本

**症状**:脚本里跑 `systemctl status xxx`,挂住不动。

**根因**:systemd 默认 PAGER,输出超过一屏就进 less,非交互环境 less 死等输入。`SYSTEMD_PAGER=` 不够,老 systemd 还读 `PAGER` / `SYSTEMD_LESS`。

**对的**(三件套):
```bash
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''
systemctl --no-pager status xxx </dev/null   # 每条 --no-pager + 子进程切 tty
```

---

### #shell-3 `set -e` 在管道里失效

**症状**:`set -e` 已经写了,但 `cmd_a | cmd_b` 里 `cmd_a` 失败,脚本继续走。

**根因**:默认管道只看最后一条的退出码。

**对的**:三件套必带 `pipefail`:
```bash
set -euo pipefail
#       ^^ pipefail = 管道任意一条非 0,整条管道就非 0
```

---

### #shell-4 macOS git case-insensitive 双跟踪文件 `git add` 静默失败

**症状**:`git status` 显示 modified,`git add file.md` 跑了不报错,`git commit` 时发现没加进去。

**根因**:Linux 上跟踪了 `README.md` 和 `readme.md` 两份(大小写不同 = 两个 inode),macOS 文件系统 case-insensitive,本地 pull 下来只能存一份。`git add` 指向的 SHA 不存在。

**修法**:
```bash
git update-index --add <path>     # 强行 stage 不存在的引用
git rm --cached <小写名>           # 长期清理,保留大写
```

---

## 网络 / iptables 类

### #net-1 `iptables-save | grep -v KUBE | iptables-restore` 整表替换 — 不要做

**症状**:执行后 docker / firewalld / Calico 自身的 iptables 规则全没了,集群网络中断。

**根因**:`grep -v KUBE` 太粗糙,会丢任何含 "KUBE" 字眼的行,而且 iptables-restore 是整表原子替换,出错就全清。

**安全替代**:
```bash
# 推荐:直接重启节点(最干净,清空 conntrack / iptables / ipvs / bpf 一次到位)
ssh node-N "reboot"

# 不重启也行:kube-proxy 已删,KUBE-* 链不会再被更新,留着无害
# 下次重启时自动消失
```

**写脚本时**:**永远不要**在 install/uninstall 脚本里包含这类整表替换命令,只能写在文档里作为"用户手动选项"且**明确标注 ⚠ 风险**。

---

### #net-2 自动检测出口网卡误选 virbr0

**症状**:自动化脚本(测网络出口、配 BGP peer 等)在测试机上跑,挑出 `virbr0` 当出口。

**根因**:libvirt 默认会建 `virbr0` 虚拟网桥,有默认路由的话会被误选。

**对的**:检测时排除常见虚拟接口:
```bash
ip route show default | grep -vE 'virbr|docker|cni|cali|veth|tun|tap' | awk '/default/ {print $5; exit}'
```

---

### #net-3 RHEL/CentOS 网络排障跳过 firewalld + SELinux

**症状**:K8s/Docker 装完连不通,日志全正常,改 ipv4_forward 也没用。

**根因**:CentOS / RHEL 默认 firewalld 启用 + SELinux enforcing。

**写脚本时**:网络相关安装脚本的 preflight 一定要检测:
```bash
if systemctl is-active firewalld >/dev/null 2>&1; then
  warn "firewalld 启用,可能拦 K8s 流量,建议:systemctl disable --now firewalld"
fi
if [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
  warn "SELinux Enforcing,建议:setenforce 0; sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config"
fi
```

---

## K8s 命令对错对照

| ✗ 错 | ✓ 对 | 为什么 |
|---|---|---|
| `kubectl create namespace x` | `kubectl create ns x --dry-run=client -o yaml \| kubectl apply -f -` | 后者幂等,前者第二次跑会报 AlreadyExists |
| `kubectl delete -f xxx.yaml`(不带 --ignore-not-found) | `kubectl delete -f xxx.yaml --ignore-not-found --timeout=180s` | 部分资源已删时不报错 |
| `kubectl apply -f xxx.yaml`(不指定 namespace,自己写) | `kubectl apply -n <ns> -f xxx.yaml`(或 yaml 里写明 ns) | 不指定可能装到错的 ns |
| `kubectl rollout restart ds/xxx`(单条) | 加 `kubectl rollout status ds/xxx --timeout=300s` 等 ready | 不等的话后续步骤可能跑在未 ready 上 |
| `kubectl logs xxx`(单条) | `kubectl logs xxx --tail=200`(或 `-c <container>` 指明) | 大日志拖死终端 / 选错 container |

---

## 脚本结构对错对照

| ✗ 错 | ✓ 对 |
|---|---|
| `#!/bin/bash` | `#!/usr/bin/env bash` |
| 没 `set -euo pipefail` | 顶部三件套必加 |
| 直接 `apt install -y` 不检测网络 | 先 `curl -kI <镜像源>` 探测 |
| 报错 echo + 继续往下走 | 报错 `exit 1`(或专门的 err 函数 → exit) |
| `dry-run` 跟 `apply` 用同一组命令,靠 if 判断 | `run()` 包装函数:`APPLY=true` 才真跑,否则只打印 |
| 默认就执行高风险操作 | 默认 `dry-run`,加 `--apply` 才真跑 |
| 用 `sleep 30 && continue` 等资源 ready | 用 `kubectl wait` / `rollout status --timeout=` |
| 删生产 ns/pv 无任何确认 | 至少 `read -p "Confirm delete ns/pv [yes/N]: "` |

---

## 何时调用此 skill

- **写新脚本前**(install.sh / uninstall.sh / 部署脚本):必看
- **改老脚本时**:必查相关条目有没有
- **脚本翻车**:症状对比清单找根因
- **review 别人的脚本 / PR**:逐条对比

## 怎么扩展这个 skill

下次再踩新坑,**直接在这个 skill 里加新条目**,不要让坑变成失忆。条目模板:

```markdown
### #<分类>-<编号> <一句话症状>

**症状**:用户看到什么
**根因**:为什么会这样
**错的**:```bash ... ```
**对的**:```bash ... ```
**写脚本时**:预防策略
```
