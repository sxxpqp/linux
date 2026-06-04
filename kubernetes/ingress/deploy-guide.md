# Kubernetes ingress-nginx v1.15.1 以 DaemonSet 模式部署实战

> 基于官方 cloud/deploy.yaml 改造,适配裸金属 / 私有云场景。完整 yaml 和配套脚本见 GitHub 仓库 https://github.com/sxxpqp/linux,本文聚焦改造思路和踩坑点。

---

## 一、为什么 DaemonSet + hostNetwork

官方 `deploy.yaml` 默认是 **Deployment + LoadBalancer Service**,这套在公有云上很好(云 LB 自动给你一个外部 IP),但在裸金属 / 私有云场景下:

- 没有云 LB,LoadBalancer Service 一直 Pending
- 用 NodePort 又得忍受 30000–32767 这种端口段,域名解析、防火墙规则都别扭
- 用 Deployment 副本只跑在某个节点,流量从其他节点进来还得跨节点转发一次

**DaemonSet + hostNetwork** 的解法很直接:

```
外部用户 → DNS → 几个节点的 IP → 节点 80/443(controller 直接 listen)
                                  ↓
                                  匹配 Ingress 规则
                                  ↓
                                  Service ClusterIP / Pod
```

- DaemonSet 保证每个**入口节点**都有一个 controller Pod
- hostNetwork=true 让 Pod 直接绑节点的 80/443/8443,不经过 kube-proxy/CNI 转发
- 客户端真实 IP 直达 controller(不丢失 source IP)
- DNS 轮询几个节点 IP 即可,或者前面挂一台外部 LB / DNS HA

对比表:

| 维度 | Deployment + LoadBalancer | **DaemonSet + hostNetwork** |
|---|---|---|
| 适用场景 | 公有云 | 裸金属 / 私有云 / 自建机房 |
| 入口 IP 来源 | 云 LB 分配 | 直接用节点 IP |
| source IP 保留 | 默认 SNAT,要 `externalTrafficPolicy: Local` 才保留 | 默认保留(走宿主机栈) |
| 网络跳数 | 4 跳(LB → kube-proxy → CNI → Pod) | 1 跳(节点 80 → Pod 直达) |
| 端口冲突 | 不存在 | 节点 80/443/8443 必须空闲 |
| 节点规划 | 任意节点都能跑 | 通常选 2-3 个专用入口节点 |

---

## 二、4 个关键字段的选型决策

改造的核心就是 4 个字段:

| 字段 | 选什么 | 为什么 |
|---|---|---|
| `kind` | `DaemonSet` | 每个入口节点一个 Pod,自动跟节点伸缩 |
| `hostNetwork` | `true` | 直接占节点 80/443,跳过 Service 转发,客户端真实 IP 直达 |
| `dnsPolicy` | `ClusterFirstWithHostNet` | **必须**,详见下面 |
| `nodeSelector` | 加自定义标签 `ingress: "true"` | 控制 Pod 调度范围,只在指定入口节点跑 |

### 关于 dnsPolicy 这个坑

K8s 的 `dnsPolicy` 在 hostNetwork 模式下行为很反直觉:

- `ClusterFirst`(默认)在 `hostNetwork: true` 时**会被 kubelet 自动降级**为 `Default`,效果等同于 Pod 直接用宿主机 `/etc/resolv.conf`
- 结果就是 Pod 里**查不到任何 `*.svc.cluster.local` 名字**,只能解析公网域名
- 表现为 controller 启动后频繁报"connection refused" / "no such host",webhook 链路断,业务诡异故障

正确做法是显式写 `ClusterFirstWithHostNet`,意思是"我用 hostNetwork,**但 DNS 仍然要走集群 CoreDNS**"。kubelet 不会降级它。

> 这一条几乎是所有 hostNetwork Pod 通用的铁律,不只 ingress-nginx。

### 关于 nodeSelector

裸金属集群里**不是每个节点都适合做入口**:

- 节点公网 IP / 防火墙规则不同
- 节点 80/443 端口可能被其他东西占用
- 业务节点跑 ingress 会跟业务 Pod 抢端口

加一个自定义标签做调度门票,例如 `ingress: "true"`:

```bash
kubectl label node node-edge-1 ingress=true --overwrite
kubectl label node node-edge-2 ingress=true --overwrite
```

只有打了标签的节点才会调度 controller Pod。新增 / 替换入口节点时,改标签就行,不动 yaml。

---

## 三、官方 yaml 改造的 5 处(以 v1.15.1 cloud/deploy.yaml 为基线)

从上游拿到完整 yaml(包含 webhook 那一整套 Job / Secret / ValidatingWebhookConfiguration,直接用,不简化)后,只需要改 controller 那个 Workload。

### 改造 1:`kind: Deployment` → `kind: DaemonSet`

```diff
 apiVersion: apps/v1
-kind: Deployment
+kind: DaemonSet
 metadata:
   name: ingress-nginx-controller
```

### 改造 2:`strategy:` → `updateStrategy:`

Deployment 用 `strategy`,DaemonSet 用 `updateStrategy`,字段名不一样:

```diff
 spec:
   minReadySeconds: 0
   revisionHistoryLimit: 10
   selector:
     matchLabels: ...
-  strategy:
+  updateStrategy:
     rollingUpdate:
       maxUnavailable: 1
     type: RollingUpdate
```

### 改造 3-5:在 `template.spec` 加 hostNetwork、改 dnsPolicy、加 nodeSelector 标签

```diff
     spec:
+      hostNetwork: true
       containers:
       - args: ...
         image: registry.k8s.io/ingress-nginx/controller:v1.15.1@sha256:...
         ...
-      dnsPolicy: ClusterFirst
+      dnsPolicy: ClusterFirstWithHostNet
       nodeSelector:
         kubernetes.io/os: linux
+        ingress: "true"
       serviceAccountName: ingress-nginx
       terminationGracePeriodSeconds: 300
```

就这 5 处,其他字段(RBAC、ConfigMap、Service、IngressClass、admission webhook Job、ValidatingWebhookConfiguration)**全部保留官方原版**,生产 webhook 功能完整可用。

### 一个可选优化:Service Type 改 ClusterIP

官方原版的 controller Service 是 `LoadBalancer`,在 hostNetwork DS 模式下意义有限(流量本身就从节点 IP 进,不经过 Service)。如果你不打算用 MetalLB 给一个统一 LB IP,可以改成 `ClusterIP`,免去 Service 一直 Pending 的提示:

```diff
 spec:
-  externalTrafficPolicy: Local
   ports: ...
-  type: LoadBalancer
+  type: ClusterIP
```

要保留 LoadBalancer + MetalLB 那套也行,不冲突 — 这步看你的入口规划。

---

## 四、节点准备:打 `ingress=true` 标签

```bash
# 看节点
kubectl get nodes -o wide

# 选 2-3 个节点作入口(通常是有外部可达 IP 的节点)
kubectl label node node-edge-1 ingress=true --overwrite
kubectl label node node-edge-2 ingress=true --overwrite
```

确保这些节点的 80/443/8443 端口空闲:

```bash
# 在每个候选节点上跑
ss -tlnp | grep -E ':(80|443|8443) '
# 期望:空输出。如果有占用(nginx / apache / 别的 ingress controller),停掉对应服务
```

防火墙开 80/443:

```bash
# firewalld
firewall-cmd --add-port=80/tcp --permanent
firewall-cmd --add-port=443/tcp --permanent
firewall-cmd --reload

# ufw
ufw allow 80/tcp
ufw allow 443/tcp
```

---

## 五、镜像加速:在 containerd 层做 mirror,不污染 yaml

官方 yaml 里 image 字段长这样:

```yaml
image: registry.k8s.io/ingress-nginx/controller:v1.15.1@sha256:594ceea76b01c592858f803f9ff4d2cb40542cae2060410b2c95f75907d659e1
```

`registry.k8s.io` 在国内基本拉不动。**有两种做法**:

| 做法 | 优 | 缺 |
|---|---|---|
| 改 yaml 里的 image 路径 | 直观 | 升级时所有 yaml 都要改,跟上游 diff 永远不一致 |
| **在 containerd 配 mirror** | yaml 跟上游字节一致,升级直接抄,各种环境复用 | 需要给每个节点配文件 |

后者更干净。containerd 1.4+ 支持 `hosts.toml` 镜像源覆盖。

### 第一步:打开 hosts.toml 读取

`/etc/containerd/config.toml` 里要有这段:

```toml
[plugins."io.containerd.grpc.v1.cri".registry]
  config_path = "/etc/containerd/certs.d"
```

检查:

```bash
grep -A1 'cri".registry' /etc/containerd/config.toml | grep config_path
# 期望输出:    config_path = "/etc/containerd/certs.d"
```

没有的话加上,然后 `systemctl restart containerd` 一次(只此一次,后续改 hosts.toml 不用重启)。

### 第二步:给 registry.k8s.io 配 mirror

```bash
mkdir -p /etc/containerd/certs.d/registry.k8s.io

cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml <<'EOF'
server = "https://registry.k8s.io"

[host."https://k8s.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

上面的 `k8s.ihome.sxxpqp.top:8443` 是我自建的 Harbor pull-through 代理,挂在 `registry.k8s.io` 上,**仅供我自己内网用**。读者请替换为自己环境的镜像加速地址,常见选择:

- 自建 Harbor / Nexus 配 pull-through cache(最推荐,各种上游 registry 都能代理)
- 阿里云容器镜像加速服务(只加速 `docker.io`)
- DaoCloud `m.daocloud.io` 等公有镜像加速
- 公司内部容器仓库

如果你同时还要加速 `docker.io` / `ghcr.io` / `quay.io`,在 `/etc/containerd/certs.d/` 下分别建对应目录(`docker.io/`、`ghcr.io/`、`quay.io/`),各放一个 `hosts.toml`,套路一样。

不用重启 containerd,hosts.toml 是运行时读取的。

### 第三步:验证

```bash
ctr -n k8s.io image pull registry.k8s.io/ingress-nginx/controller:v1.15.1
# 拉成功就说明 mirror 配置生效
```

可以顺手把 `docker.io` / `ghcr.io` / `quay.io` 几个常用上游也按同样模式配上,一劳永逸。

---

## 六、apply + 验证

```bash
# apply 改造后的 yaml
kubectl apply -f deploy.yaml

# 等 DaemonSet 起来
kubectl -n ingress-nginx rollout status ds/ingress-nginx-controller --timeout=300s

# 看 Pod 分布(应该在打了标签的几个节点上)
kubectl -n ingress-nginx get pods -o wide

# 看 webhook 资源到位
kubectl -n ingress-nginx get jobs              # 2 个 admission-create / admission-patch 应 Completed
kubectl get validatingwebhookconfiguration ingress-nginx-admission

# 看 IngressClass
kubectl get ingressclass nginx
```

节点 80 端口连通性测试:

```bash
# 在任一打标签的节点 IP 上
curl -I http://<node-ip>:80

# 期望:HTTP/1.1 404 Not Found
# 含义:controller 在 listen,只是没匹配到 Ingress 规则,符合预期
```

---

## 七、跑一个最小 Ingress 测试

部署一个 nginx Pod 暴露成 Service,然后通过 Ingress 路由:

```yaml
# test-ingress.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo
spec:
  replicas: 1
  selector:
    matchLabels: { app: demo }
  template:
    metadata:
      labels: { app: demo }
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: demo
spec:
  selector: { app: demo }
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: demo
spec:
  ingressClassName: nginx           # 关联到我们刚装的 controller
  rules:
    - host: demo.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: demo
                port:
                  number: 80
```

```bash
kubectl apply -f test-ingress.yaml

# 验证(用 Host 头模拟 DNS)
curl -H "Host: demo.example.com" http://<打标签的节点 IP>/
# 期望:nginx 默认页(<title>Welcome to nginx!</title>)
```

通了就说明:节点 IP → controller → Ingress 规则匹配 → demo Service → demo Pod 整条链路 OK。

---

## 八、踩坑速查

| 现象 | 原因 | 修法 |
|---|---|---|
| Pod 一直 Pending,`didn't match Pod's node affinity` | 没节点打 `ingress=true` 标签 | `kubectl label node <N> ingress=true --overwrite` |
| Pod CrashLoop,日志 `bind: address already in use` | 节点 80/443/8443 被占 | `ss -tlnp \| grep ':80'` 找占用方,停掉 |
| controller 日志一直 "no such host" / 解析失败 | `dnsPolicy: ClusterFirst` 没改成 `ClusterFirstWithHostNet` | yaml 里改字段,重 apply |
| `ImagePullBackOff: manifest digest doesn't match` | 镜像加速代理 rewrite 后 digest 跟上游不一致 | yaml 里去掉 `@sha256:...` 只用 tag,或者拉到本地后用真实 digest 替换 |
| webhook 报 `connection refused` | controller Pod 没起来,admission Service 拨号失败 | 先确保 controller Pod Running,再 apply Ingress 资源 |
| apply Ingress 报 `denied the request: ...` | webhook 拦截,nginx config 编译失败(典型是 `configuration-snippet` 注解写错) | 看错误信息修 yaml,这是 webhook 在帮你 |
| 装完 Pod Running 但外网超时 | 节点防火墙没开 80/443 | `firewall-cmd --add-port=80/tcp --permanent && firewall-cmd --reload` |
| 创建 Ingress 后规则不生效 | yaml 里漏了 `ingressClassName: nginx` | 加上 |

---

## 完整 yaml 与配套脚本

文章里的 yaml 是片段 diff,完整版(包括 webhook 配套的 Job / Secret / ValidatingWebhookConfiguration / RBAC,共 660 行)和配套的安装/卸载脚本,在我的 GitHub 仓库:

**https://github.com/sxxpqp/linux**

路径 `kubernetes/ingress/`。仓库里还有 Calico CNI、kube-proxy 替换 eBPF、MetalLB、cert-manager 等周边组件的部署记录,一起作为裸金属 K8s 集群参考。

---

## 小结

四个字段切换,把官方 cloud 版变成裸金属可用的 DaemonSet + hostNetwork 入口:

1. `kind: DaemonSet`
2. `hostNetwork: true`
3. `dnsPolicy: ClusterFirstWithHostNet`(铁律,别忘)
4. `nodeSelector: ingress: "true"`(灵活控制入口节点)

镜像加速放在 containerd 层做,yaml 保持上游原版,升级时直接抄新版本号,改 4 个字段重 apply,完事。
