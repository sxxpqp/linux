# kubeadm init 完整过程详解

从执行 `kubeadm init` 到集群就绪，每一步做了什么。

---

## 一、前置检查（Preflight Checks）

`kubeadm init` 最开始做的就是检查环境。

```
· OS 兼容性（Linux only）
· kubelet 已安装但未运行
· containerd / CRI 已安装且可用
· swap 必须关闭（kubelet 要求）
· 端口未被占用：
  ├── 6443（apiserver）
  ├── 10250（kubelet）
  ├── 10257（controller-manager）
  ├── 10259（scheduler）
  ├── 2379 / 2380（etcd）
· /proc/sys/net/bridge/bridge-nf-call-iptables = 1
· /proc/sys/net/ipv4/ip_forward = 1
· /etc/kubernetes/manifests/ 目录不存在或为空
  ├── 防止残留 static pod 干扰
· /var/lib/etcd/ 目录不存在或为空
  ├── 防止残留 etcd 数据干扰
```

任一检查不通过 → 直接报错退出。

可以通过 `--ignore-preflight-errors` 跳过，但不推荐。

---

## 二、生成证书（Certificate Authority）

这是集群的身份证。

```
生成位置：/etc/kubernetes/pki/

├── ca.crt + ca.key               ← K8s 根 CA
│    ├── apiserver.crt + .key     ← apiserver 证书
│    ├── apiserver-kubelet-client.crt + .key
│    │                            ← apiserver 连接 kubelet 用
│    ├── front-proxy-ca.crt + .key
│    │    └── front-proxy-client.crt + .key
│    │                            ← apiserver 扩展代理
│    └── sa.pub + sa.key          ← ServiceAccount 签名
├── etcd/
│    └── ca.crt + ca.key          ← etcd 根 CA
│         ├── apiserver-etcd-client.crt + .key  ← apiserver 连 etcd
│         ├── server.crt + .key   ← etcd server 证书
│         └── peer.crt + .key     ← etcd 节点间通信
```

如果指定了 `--cert-dir` 且目录下有 ca.crt + ca.key，则跳过生成，**直接用旧的**。这是 etcd 恢复时用旧 CA 重建的关键。

---

## 三、生成 kubeconfig 文件

```
生成位置：/etc/kubernetes/

├── admin.conf             ← 集群管理员，跳过 RBAC
│                            server: https://<control-plane-endpoint>:6443
├── kubelet.conf           ← kubelet 用来连 apiserver
│                            server: https://<LB or master IP>:6443
├── controller-manager.conf
│    └── controller-manager 连 apiserver 用
└── scheduler.conf
     └── scheduler 连 apiserver 用
```

每个 kubeconfig 都包含：
```
· server 地址（当前是指定的 control-plane-endpoint）
· CA 证书
· 该组件专用的客户端证书（上一步生成的）
```

注意：此时**还没有 etcd 数据**，但文件已经写好了。

---

## 四、生成 static pod 清单（最关键的一步）

```
生成位置：/etc/kubernetes/manifests/

├── etcd.yaml              ← etcd 容器定义
├── kube-apiserver.yaml    ← apiserver 容器定义
├── kube-controller-manager.yaml
└── kube-scheduler.yaml
```

kubelet 会**监控这个目录**，发现 yaml 文件就自动拉起对应的 static pod。

### etcd.yaml

通过 `--config` 参数传递给 etcd 的内容：

```
· 数据目录：/var/lib/etcd
· 监听端口：
  ├── 2379  ← apiserver 连 etcd
  └── 2380  ← etcd 节点间通信
· 集群名称：default
· 证书路径：/etc/kubernetes/pki/etcd/
· 单节点模式（init 阶段只有一个节点）
```

作为 static pod 运行，没有 deployment、没有 pod 对象、kubectl get pods -n kube-system 看不到它属于什么控制器。

### kube-apiserver.yaml

启动参数非常多，核心的有：

```
· --etcd-servers=https://127.0.0.1:2379
  ← 连本机 etcd
· --advertise-address=<本机 IP>
  ← 对外宣告的地址
· --secure-port=6443
  ← 主入口端口
· --service-cluster-ip-range=10.96.0.0/12
  ← Service 使用的虚拟 IP 段
· --service-account-key-file=/etc/kubernetes/pki/sa.pub
· --client-ca-file=/etc/kubernetes/pki/ca.crt
· --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
· --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
· --kubelet-client-certificate=...
· --kubelet-client-key=...
· --authorization-mode=Node,RBAC
  ← 鉴权模式
· --enable-admission-plugins=...
  ← 准入控制插件列表
```

以上参数全部来自 kubeadm 的默认配置 + `--control-plane-endpoint` + `--service-cidr` 等用户参数。

### kube-controller-manager.yaml

```
· --kubeconfig=/etc/kubernetes/controller-manager.conf
· --controllers=*,bootstrapsigner,tokencleaner
  ← 所有控制器都启用
· --node-monitor-grace-period=40s
· --pod-eviction-timeout=5m0s
· --requestheader-client-ca-file=...
· --service-account-private-key-file=/etc/kubernetes/pki/sa.key
```

### kube-scheduler.yaml

```
· --kubeconfig=/etc/kubernetes/scheduler.conf
```

调度器配置最简单，没有额外参数。

---

## 五、kubelet 拉起 static pod

```
kubelet 扫描 /etc/kubernetes/manifests/
├── 发现 etcd.yaml → 拉镜像 → 启动 etcd 容器
├── 发现 kube-apiserver.yaml → 拉镜像 → 启动 apiserver
├── 发现 kube-controller-manager.yaml → 拉镜像 → 启动 controller-manager
└── 发现 kube-scheduler.yaml → 拉镜像 → 启动 scheduler

kubelet 持续监控这四个 yaml 文件，改了就重新启动对应的 Pod。
```

启动顺序依赖：
```
etcd → apiserver → controller-manager + scheduler
```

apiserver 必须等 etcd 就绪才能启动成功。controller-manager 和 scheduler 不依赖顺序，但都依赖 apiserver 就绪。

---

## 六、自举 TLS Bootstrap（kubelet 注册）

这一步让其他节点的 kubelet 能自动获取证书加入集群。

```
创建 RBAC 资源：
├── ClusterRole: system:node-bootstrapper
├── ClusterRoleBinding: kubeadm:kubelet-bootstrap
├── ConfigMap: kubelet-config (在 kube-system)
├── ConfigMap: kube-proxy-config (在 kube-system)

创建 token：
├── bootstrap-token-xxxxx (secret 形式)
├── 默认有效期 24 小时
├── 用于 kubeadm join 的发现和认证
└── 包含 token-id + token-secret
```

---

## 七、安装附加组件

```
创建以下 Deployment：
├── coredns × 2 副本
│   ├── 集群 DNS 服务
│   └── 没有 CNI 时处于 Pending（网络不通）
├── kube-proxy × DaemonSet
│   ├── 每个节点一个 Pod
│   ├── 负责 Service 的 DNAT 规则
│   └── 模式：iptables（默认）/ IPVS
```

coredns 和 kube-proxy 的镜像地址可以通过 `--image-repository` 指定。

---

## 八、标记节点

```
kubectl taint node <name> node-role.kubernetes.io/control-plane:NoSchedule
├── 默认给 master 节点打污点
├── 普通 Pod 不会调度到 master
└── 可以通过 --taint 自定义

kubectl label node <name> node-role.kubernetes.io/control-plane=
├── 标记为 control-plane 角色
├── 用于区分 master 和 worker
└── 早期版本叫 node-role.kubernetes.io/master
```

---

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

---

## 十、完整流程时间线

```
0s     → kubeadm init 执行
1-3s   → Preflight Checks
3-10s  → 生成 CA + 证书（主要耗时在 RSA 密钥生成）
10-30s → 生成 kubeconfig
30-35s → 生成 static pod 清单（yaml 文件）
35-40s → kubelet 感知到 manifests/ 目录变化
40-60s → kubelet 拉取 etcd + apiserver + controller + scheduler 镜像
60-90s → etcd 容器启动，等待 ready
90-120s→ apiserver 启动，等待 etcd 就绪
120-130s→ controller-manager + scheduler 启动
130-150s→ TLS bootstrap + 创建 token + 创建 kube-proxy + coredns
150-160s→ 打 taint + label，输出 join 命令
```

实际时间取决于镜像拉取速度。用 `--image-repository` 指定国内镜像源能快很多。

---

## 附：涉及的关键路径

```
文件：
  /etc/kubernetes/
  ├── pki/
  ├── manifests/
  │   └── etcd.yaml, kube-apiserver.yaml, kube-controller-manager.yaml, kube-scheduler.yaml
  ├── admin.conf
  ├── kubelet.conf
  ├── controller-manager.conf
  └── scheduler.conf
  /var/lib/etcd/

容器（static pod）：
  kube-system namespace
  ├── etcd-<hostname>
  ├── kube-apiserver-<hostname>
  ├── kube-controller-manager-<hostname>
  └── kube-scheduler-<hostname>

集群资源：
  kube-system namespace
  ├── Deployment/coredns
  ├── DaemonSet/kube-proxy
  ├── ClusterRole/system:node-bootstrapper
  ├── Secret/bootstrap-token-*
  └── ConfigMap/kubelet-config / kube-proxy-config
```
