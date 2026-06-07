# kubeadm reset 你真的了解吗

## 它不是什么本地清理工具

`kubeadm reset` 不是纯粹的本机操作。它会读 `/etc/kubernetes/admin.conf`，只要能连上 API，就能远程操作你的集群。

## 连上 API 的条件

不是有 admin.conf 就能连：

```
地址能通    → 网络可达
CA 一致     → 集群没重建过
凭证有效    → token/cert 未被 revoke
API 活着    → api-server 在跑
```

四样全齐才能远程作妖，缺一样就只清本地。

## 默认行为

不指定 `--node-name` 时：

- 本机 hostname 匹配 member → 删自己
- 不匹配 → 报错退出，不动别人

指定 `--node-name` 时，就是定点远程删除了。

## admin.conf 指向 LB 的风险

```
admin.conf 指向 VIP
→ reset 打到 LB
→ LB 随手分到某台 master
→ 你根本不知道删了谁
```

如果 admin.conf 写的不是具体节点 IP，而是 `--control-plane-endpoint` 指定的地址，reset 的目标就是不确定的。

## kubectl 日常怎么用

admin.conf 指向 127.0.0.1 之后，kubectl 的用法就分清楚了：

```bash
# 场景一：日常操作 —— 走 LB
kubectl --kubeconfig ~/.kube/config-lb get nodes

# 场景二：apiserver 挂了 —— 走本机排查
kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -n kube-system

# 或者把 LB 配置设成默认，省事
export KUBECONFIG=~/.kube/config-lb
```

**~/.kube/config-lb 长这样：**

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

这样：

```
/etc/kubernetes/admin.conf   → 127.0.0.1   → kubeadm reset 只删本机
~/.kube/config-lb            → LB 地址     → kubectl 日常走 LB
```

两不耽误。

## 最佳实践：每台 master 指向自己

```yaml
# /etc/kubernetes/admin.conf
server: https://127.0.0.1:6443
```

好处：
- reset 只删自己，不伤别人
- 本机 kubectl 更快，不经过 LB

坏处：
- API server 挂了本机 kubectl 也用不了

所以建议手上再留一份指向 LB 的 config。

## 高危场景总结

```
· admin.conf 拷到别的机器 + kubeadm reset
  → 等于把远程删除开关送出去了

· 节点重装后 hostname 变了 + 旧 member 没删
  → 匹配失败，member list 可能残留僵尸

· LB 做 control-plane-endpoint + 执行 reset 忘了看目标
  → 删了哪台都不知道
```

## 清理范围

**清理了什么：**

```
容器层面：
  ├── kube-system 下 static pod（apiserver/etcd/controller/scheduler）
  ├── kube-proxy、coredns 等

文件层面：
  ├── /etc/kubernetes/manifests/  → static pod 清单
  ├── /etc/kubernetes/pki/        → TLS 证书密钥
  ├── /etc/kubernetes/admin.conf  → kubeconfig
  ├── /var/lib/kubelet/           → kubelet 数据
  └── /var/lib/etcd/              → etcd 数据（--force 才会清）

系统层面：
  ├── kubelet 服务 stop + disable
  ├── containerd/docker 不动
  ├── CNI 配置残留（需手动清理）
  └── iptables 规则 flush
```

**不会动的：**

```
✅ 应用 Pod PV 数据（挂外部存储的不影响）
✅ containerd / docker 本身
✅ 节点上的普通用户进程
✅ /opt/cni/bin/ → CNI 二进制（需手动删）
✅ /etc/cni/net.d/ → CNI 配置（需手动删）
✅ sshd、监控 agent 等其他宿主机服务
```
