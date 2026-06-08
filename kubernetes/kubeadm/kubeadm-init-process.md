# kubeadm init 完整过程详解

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/kubeadm/kubeadm-init-process.md
> 状态: 学习笔记

从执行 `kubeadm init` 到集群就绪,每一步做了什么。

## 目录

1. [前置检查 Preflight Checks](#一前置检查preflight-checks)
2. [生成证书 CA](#二生成证书certificate-authority)
3. [生成 kubeconfig](#三生成-kubeconfig-文件)
4. [生成 static pod 清单(最关键)](#四生成-static-pod-清单最关键的一步)
5. [kubelet 拉起 static pod](#五kubelet-拉起-static-pod)
6. [TLS Bootstrap](#六自举-tls-bootstrapkubelet-注册)
7. [安装附加组件](#七安装附加组件)
8. [标记节点](#八标记节点)
9. [输出结果](#九输出结果)
10. [完整流程时间线](#十完整流程时间线)

---

## 一、前置检查(Preflight Checks)

任一检查不通过 → 直接报错退出。`--ignore-preflight-errors` 可以跳过,不推荐。

**系统环境:**

- OS 兼容性(Linux only)
- kubelet 已安装但未运行
- containerd / CRI 已安装且可用
- swap 必须关闭(kubelet 要求)
- `/proc/sys/net/bridge/bridge-nf-call-iptables = 1`
- `/proc/sys/net/ipv4/ip_forward = 1`

**端口未被占用:**

| 端口 | 组件 |
|---|---|
| 6443 | apiserver |
| 10250 | kubelet |
| 10257 | controller-manager |
| 10259 | scheduler |
| 2379 / 2380 | etcd |

**残留检查:**

- `/etc/kubernetes/manifests/` 不存在或为空(防 static pod 干扰)
- `/var/lib/etcd/` 不存在或为空(防旧 etcd 数据干扰)

## 二、生成证书(Certificate Authority)

集群的身份证。生成位置:`/etc/kubernetes/pki/`

```
├── ca.crt + ca.key               # K8s 根 CA
│   ├── apiserver.crt + .key      # apiserver 证书
│   ├── apiserver-kubelet-client.*# apiserver 连接 kubelet
│   ├── front-proxy-ca.*          # 扩展代理根
│   │   └── front-proxy-client.*
│   └── sa.pub + sa.key           # ServiceAccount 签名
└── etcd/
    └── ca.crt + ca.key           # etcd 根 CA
        ├── apiserver-etcd-client.*  # apiserver 连 etcd
        ├── server.*              # etcd server
        └── peer.*                # etcd 节点间通信
```

> 如果指定 `--cert-dir` 且目录下已有 `ca.crt + ca.key`,**直接用旧的**,不重新生成。这是 etcd 恢复时"用旧 CA 重建"的关键(见 [etcd/recovery.md](../etcd/recovery.md))。

## 三、生成 kubeconfig 文件

生成位置:`/etc/kubernetes/`

| 文件 | 用途 | server 指向 |
|---|---|---|
| `admin.conf` | 集群管理员,跳过 RBAC | `<control-plane-endpoint>:6443` |
| `kubelet.conf` | kubelet 连 apiserver | `<LB or master IP>:6443` |
| `controller-manager.conf` | controller-manager 连 apiserver | 同上 |
| `scheduler.conf` | scheduler 连 apiserver | 同上 |

每个 kubeconfig 都包含:server 地址 + CA 证书 + 该组件专用的客户端证书(上一步生成)。

> 此时**还没有 etcd 数据**,但文件已经写好了。

## 四、生成 static pod 清单(最关键的一步)

生成位置:`/etc/kubernetes/manifests/`

- `etcd.yaml`
- `kube-apiserver.yaml`
- `kube-controller-manager.yaml`
- `kube-scheduler.yaml`

kubelet **监控这个目录**,发现 yaml 就自动拉起对应 static pod。

### etcd.yaml

| 项 | 值 |
|---|---|
| 数据目录 | `/var/lib/etcd` |
| 客户端端口 | 2379(apiserver → etcd) |
| 节点通信 | 2380(etcd ↔ etcd) |
| 集群名称 | `default` |
| 证书路径 | `/etc/kubernetes/pki/etcd/` |
| 模式 | 单节点(init 阶段) |

static pod 直接由 kubelet 管,**没有 Deployment / 控制器对象**,`kubectl get pods -n kube-system` 看不到归属。

### kube-apiserver.yaml

核心启动参数:

```
--etcd-servers=https://127.0.0.1:2379          # 连本机 etcd
--advertise-address=<本机 IP>                   # 对外宣告
--secure-port=6443
--service-cluster-ip-range=10.96.0.0/12        # Service VIP 段
--service-account-key-file=/etc/kubernetes/pki/sa.pub
--client-ca-file=/etc/kubernetes/pki/ca.crt
--tls-cert-file=/etc/kubernetes/pki/apiserver.crt
--tls-private-key-file=/etc/kubernetes/pki/apiserver.key
--kubelet-client-certificate=...
--kubelet-client-key=...
--authorization-mode=Node,RBAC                 # 鉴权
--enable-admission-plugins=...                 # 准入控制
```

参数来源:kubeadm 默认配置 + `--control-plane-endpoint` + `--service-cidr` 等用户参数。

### kube-controller-manager.yaml

```
--kubeconfig=/etc/kubernetes/controller-manager.conf
--controllers=*,bootstrapsigner,tokencleaner   # 全启用
--node-monitor-grace-period=40s
--pod-eviction-timeout=5m0s
--requestheader-client-ca-file=...
--service-account-private-key-file=/etc/kubernetes/pki/sa.key
```

### kube-scheduler.yaml

```
--kubeconfig=/etc/kubernetes/scheduler.conf
```

调度器最简单,没有额外参数。

## 五、kubelet 拉起 static pod

```
扫描 /etc/kubernetes/manifests/
  → 发现 etcd.yaml                    → 拉镜像 → 启动 etcd
  → 发现 kube-apiserver.yaml          → 拉镜像 → 启动 apiserver
  → 发现 kube-controller-manager.yaml → 拉镜像 → 启动 controller-manager
  → 发现 kube-scheduler.yaml          → 拉镜像 → 启动 scheduler
```

kubelet 持续监控这四个 yaml,改了就重启对应 Pod。

**启动顺序依赖:** `etcd → apiserver → controller-manager + scheduler`。apiserver 必须等 etcd 就绪;controller-manager / scheduler 都依赖 apiserver 就绪,但彼此无序。

## 六、自举 TLS Bootstrap(kubelet 注册)

让其他节点的 kubelet 自动获取证书加入集群。

**创建 RBAC 资源:**

- `ClusterRole: system:node-bootstrapper`
- `ClusterRoleBinding: kubeadm:kubelet-bootstrap`
- `ConfigMap: kubelet-config`(kube-system)
- `ConfigMap: kube-proxy-config`(kube-system)

**创建 token:**

- `bootstrap-token-xxxxx`(Secret 形式)
- 默认有效期 24 小时
- 用于 `kubeadm join` 的发现 + 认证
- 包含 token-id + token-secret

## 七、安装附加组件

| 资源 | 类型 | 说明 |
|---|---|---|
| coredns | Deployment × 2 | 集群 DNS;无 CNI 时 Pending(网络不通) |
| kube-proxy | DaemonSet | 每节点一个 Pod,负责 Service DNAT,默认 iptables 模式 |

镜像地址可通过 `--image-repository` 指定。

## 八、标记节点

```bash
kubectl taint node <name> node-role.kubernetes.io/control-plane:NoSchedule
kubectl label node <name> node-role.kubernetes.io/control-plane=
```

- 默认给 master 打污点,普通 Pod 不调度过来
- `--taint` 可自定义
- 早期版本用 `node-role.kubernetes.io/master`

## 九、输出结果

```
Your Kubernetes control-plane has been initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

You can now join any number of control-plane nodes by copying certificate authorities
and service account keys on each node and then running the following as root:

  kubeadm join <control-plane-endpoint>:6443 --token <token> \
        --discovery-token-ca-cert-hash sha256:<hash> \
        --control-plane

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join <control-plane-endpoint>:6443 --token <token> \
        --discovery-token-ca-cert-hash sha256:<hash>
```

## 十、完整流程时间线

| 时间 | 阶段 | 做什么 |
|---|---|---|
| 0s | 启动 | `kubeadm init` 执行 |
| 1–3s | Preflight | 环境检查 |
| 3–10s | 证书 | 生成 CA + 子证书(RSA 密钥生成最耗时) |
| 10–30s | kubeconfig | 4 份 conf 文件 |
| 30–35s | manifests | 4 个 static pod yaml |
| 35–40s | kubelet 感知 | 扫描 manifests/ |
| 40–60s | 拉镜像 | etcd / apiserver / controller / scheduler |
| 60–90s | etcd 启动 | 等待 ready |
| 90–120s | apiserver 启动 | 等 etcd 就绪 |
| 120–130s | 其他控制面 | controller-manager + scheduler |
| 130–150s | bootstrap | TLS bootstrap + token + kube-proxy + coredns |
| 150–160s | 收尾 | taint + label,输出 join 命令 |

实际时间取决于镜像拉取速度。**镜像走 mirror**(本仓库节点已配 Harbor mirror,见 [docker/containerd/mirrors.sh](../../docker/containerd/mirrors.sh))能快很多。

## 附:涉及的关键路径

**文件:**

```
/etc/kubernetes/
├── pki/
├── manifests/
│   ├── etcd.yaml
│   ├── kube-apiserver.yaml
│   ├── kube-controller-manager.yaml
│   └── kube-scheduler.yaml
├── admin.conf
├── kubelet.conf
├── controller-manager.conf
└── scheduler.conf
/var/lib/etcd/
```

**static pod(kube-system namespace):**

- `etcd-<hostname>`
- `kube-apiserver-<hostname>`
- `kube-controller-manager-<hostname>`
- `kube-scheduler-<hostname>`

**集群资源(kube-system namespace):**

- `Deployment/coredns`
- `DaemonSet/kube-proxy`
- `ClusterRole/system:node-bootstrapper`
- `Secret/bootstrap-token-*`
- `ConfigMap/kubelet-config`、`ConfigMap/kube-proxy-config`
