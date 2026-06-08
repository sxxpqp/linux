# kubeadm reset 你真的了解吗

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/kubeadm/kubeadm-reset.md
> 状态: 学习笔记

## 它不是本地清理工具

`kubeadm reset` 不是纯本机操作。它会读 `/etc/kubernetes/admin.conf`,只要能连上 API,就能远程操作集群。

## 能连上 API 的四个条件

| 条件 | 说明 |
|---|---|
| 地址能通 | 网络可达 |
| CA 一致 | 集群没重建过 |
| 凭证有效 | token / cert 未被 revoke |
| API 活着 | apiserver 在跑 |

四样全齐才能远程作妖,缺一样就只清本地。

## 默认行为

不指定 `--node-name` 时:

- 本机 hostname 匹配 member → 删自己
- 不匹配 → 报错退出,不动别人

指定 `--node-name` 就是定点远程删除。

## admin.conf 指向 LB 的风险

admin.conf 写的不是具体节点 IP,而是 `--control-plane-endpoint` 指定的 VIP → reset 打到 LB → LB 随手分到某台 master → **你根本不知道删了谁**。

## kubectl 日常怎么用

让 admin.conf 指向 `127.0.0.1`,日常 kubectl 走 LB,两份 kubeconfig 分工:

| 文件 | 指向 | 用途 |
|---|---|---|
| `/etc/kubernetes/admin.conf` | `127.0.0.1` | kubeadm reset 只删本机 / apiserver 挂了排查 |
| `~/.kube/config-lb` | LB 地址 | kubectl 日常,负载均衡 |

```bash
# 日常 —— 走 LB
kubectl --kubeconfig ~/.kube/config-lb get nodes

# apiserver 挂了 —— 走本机
kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -n kube-system

# 把 LB 设默认,省事
export KUBECONFIG=~/.kube/config-lb
```

`~/.kube/config-lb` 模板:

```yaml
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://172.16.0.10:6443    # ← 你的 LB 地址
    certificate-authority-data: ...      # ← 跟 admin.conf 一样的 CA
  name: kubernetes
users:
- name: kubernetes-admin
  user:
    client-certificate-data: ...
    client-key-data: ...
contexts:
- context:
    cluster: kubernetes
    user: kubernetes-admin
  name: default
current-context: default
```

## 最佳实践:每台 master 指向自己

```yaml
# /etc/kubernetes/admin.conf
server: https://127.0.0.1:6443
```

- ✅ reset 只删自己,不伤别人
- ✅ 本机 kubectl 更快,不经过 LB
- ❌ apiserver 挂了本机 kubectl 也用不了 → 手上再留一份指向 LB 的 config

## 高危场景

| 场景 | 后果 |
|---|---|
| admin.conf 拷到别的机器 + `kubeadm reset` | 等于把远程删除开关送出去了 |
| 节点重装后 hostname 变了 + 旧 member 没删 | 匹配失败,member list 残留僵尸 |
| LB 做 control-plane-endpoint + 执行 reset 忘了看目标 | 删了哪台都不知道 |

## 清理范围

| 层 | 会清 | 不会动 |
|---|---|---|
| **容器** | kube-system 下 static pod(apiserver / etcd / controller / scheduler)、kube-proxy、coredns | 应用 Pod、containerd / docker 本身 |
| **文件** | `/etc/kubernetes/manifests/`、`/etc/kubernetes/pki/`、`/etc/kubernetes/admin.conf`、`/var/lib/kubelet/`、`/var/lib/etcd/`(需 `--force`) | 挂外部存储的 PV 数据、`/opt/cni/bin/`、`/etc/cni/net.d/`(需手动清) |
| **系统** | kubelet 服务 stop + disable、iptables 规则 flush | containerd / docker、sshd、监控 agent、普通用户进程 |
