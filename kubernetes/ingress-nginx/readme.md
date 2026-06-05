# ingress-nginx v1.15.1 — 裸金属生产部署(DaemonSet + BGP-LB / hostNetwork)

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/ingress-nginx/readme.md
> 状态: ✅ 生产验证

裸金属 K8s 入口方案。DaemonSet 跑在多个标记节点,**两种暴露模式**按场景选:

| 模式 | 暴露方式 | 客户端可达 | 配套 |
|---|---|---|---|
| **A. hostNetwork**(当前默认) | DS Pod 直绑节点 80/443 | DNS 轮询节点 IP / 外部 LB | 单独用,无需 Calico LB |
| **B. Service LoadBalancer + BGP ECMP**(生产推荐) | DS Pod 走 ClusterIP,Service 类型 LoadBalancer 暴露 | 单一 LB IP,**路由器 ECMP 负载均衡到多节点** | 配 [Calico BGP-LB](../calico/bgp-lb/) |

模式 B 才是真正生产意义上"多入口节点 + 高可用 + 单 VIP"的方案;模式 A 简单,适合内网测试 / DNS HA。

## TL;DR

```bash
# 1. 安装(给 node1/node2 打标签 + 部署 DS)
bash install.sh --label-nodes=node1,node2

# 2A. hostNetwork 模式验证(就地直通)
curl -I http://172.16.150.129:80   # 期望: 404 Not Found(controller 在 listen)
curl -I http://172.16.150.130:80

# 2B. BGP-LB 模式验证(配合 Calico BGP-LB)
kubectl get svc -n ingress-nginx ingress-nginx-controller   # EXTERNAL-IP 应该是 172.16.150.200
curl -I http://172.16.150.200:80

# 端到端测试
bash test.sh

# 卸载
bash uninstall.sh --apply
```

---

## 生产架构:模式 B(BGP-LB + ECMP)

```
                  外部客户端
                      │
                      ▼
            ┌─────────────────────┐
            │    外部路由器        │
            │    (AS 64500)       │
            │                     │
            │ 172.16.150.200/32:  │  ← BGP ECMP 多 nexthop
            │   via .129 weight 1 │
            │   via .130 weight 1 │
            └──────┬──────────┬───┘
                   │          │
        ┌──────────┘          └──────────┐
        ▼                                ▼
  ┌──────────────┐               ┌──────────────┐
  │ node1 .129   │               │ node2 .130   │
  │ ingress=true │               │ ingress=true │
  │              │               │              │
  │ ingress-nginx│               │ ingress-nginx│
  │  DS Pod      │               │  DS Pod      │
  └──────┬───────┘               └──────┬───────┘
         │                              │
         └──────────────┬───────────────┘
                        ▼
                Service(ClusterIP)
                        ▼
                    业务 Pod
```

**关键链路**:

1. ingress-nginx **DaemonSet** 调度到打了 `ingress=true` 标签的节点(`--label-nodes=node1,node2`)
2. ingress-nginx **Service** 类型 `LoadBalancer`,`externalTrafficPolicy: Local`,`lb-assigner` 自动分配 `172.16.150.200`
3. Calico BIRD 在 `node1` + `node2` 上**都向路由器宣告 `172.16.150.200/32`**(因为这俩节点有 backend Pod)
4. 路由器收到 2 条相同 prefix,**ECMP** 安装多 nexthop,按 5-tuple 哈希挑节点
5. 节点上 controller 接到流量 → 匹配 Ingress 规则 → 转给后端 Service / Pod

详见 [../calico/bgp-lb/README.md](../calico/bgp-lb/README.md) 的 "BGP ECMP 工作原理" 段。

---

## 部署模型字段速查

| 字段 | 模式 A(hostNetwork) | 模式 B(BGP-LB) |
|---|---|---|
| `kind` | `DaemonSet` | `DaemonSet` |
| `nodeSelector` | `ingress: "true"`(用 `--label-nodes=` 自动打) | 同左 |
| `hostNetwork` | **`true`** — 节点 80/443 直通 | `false` — 走 Pod 网络 |
| `dnsPolicy` | **`ClusterFirstWithHostNet`** — hostNetwork 必配,否则 cluster DNS 解不到 | `ClusterFirst`(默认) |
| `Service.type` | `NodePort` 或不用 Service | **`LoadBalancer`** |
| `Service.externalTrafficPolicy` | n/a | **`Local`** — 保留客户端 IP + ECMP 路径数 = DS 实例数 |
| 客户端入口 | 节点 IP `:80/:443` | LB IP(本环境 `172.16.150.200`) |

> ⚠ `dnsPolicy: ClusterFirstWithHostNet` 是 hostNetwork 模式的硬性要求 — 不配会被 kubelet 静默降级成 `Default`,Pod 解析不到 `*.svc.cluster.local`,webhook 链路断。详见 [deploy-guide.md](deploy-guide.md) "关于 dnsPolicy 这个坑" 段。

---

## 文件

| 文件 | 状态 | 说明 |
|---|---|---|
| [install.sh](install.sh) | ✅ | 安装脚本:打节点标签 → apply deploy.yaml → 等 DS/Jobs ready → 验证 80 端口 |
| [uninstall.sh](uninstall.sh) | ✅ | 卸载脚本:删 DS → 清 Pod → 剥 namespace finalizer,默认 dry-run |
| [deploy.yaml](deploy.yaml) | ✅ | ingress-nginx v1.15.1 完整部署(DaemonSet + hostNetwork + admission webhook) |
| [deploy-guide.md](deploy-guide.md) | 参考 | **改造思路 + 4 字段选型 + dnsPolicy 坑 + 镜像加速**(技术深度) |
| [test.sh](test.sh) | ✅ | **验证脚本**:部署测试应用 → Pod→ClusterIP → 集群内 Ingress → 外部 Ingress |
| [ingress-demo.yaml](ingress-demo.yaml) | 参考 | 最简 Ingress 示例 |
| [ingress-example.yaml](ingress-example.yaml) | 参考 | TLS + 多路径 rewrite 示例 |
| [test.yaml](test.yaml) | 参考 | 测试 Deployment + Service + Ingress |
| [values.yaml](values.yaml) | 参考 | Helm values(跟 deploy.yaml 互补) |

## 前置

```bash
# 1. containerd registry.k8s.io 加速(每个节点)
mkdir -p /etc/containerd/certs.d/registry.k8s.io
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml << EOF
server = "https://registry.k8s.io"
[host."https://k8s.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

# 2. 打入口节点标签(也可以让 install.sh --label-nodes= 帮你打)
kubectl label node node1 ingress=true --overwrite
kubectl label node node2 ingress=true --overwrite
```

完整 hosts.toml 模板见 [docs/infra-reference.md](../../docs/infra-reference.md) "Docker / containerd 加速源配置"。

## 安装步骤

详见 [install.sh](install.sh)。整体 5 步:

1. 前置检查(kubectl / deploy.yaml)
2. 给指定节点打 `ingress=true` 标签
3. `kubectl apply -f deploy.yaml`
4. 等 DS rollout + admission Jobs 完成
5. 验证 80 端口在 listen

改造思路(为什么这么改 + 4 字段选型)见 [deploy-guide.md](deploy-guide.md)。

---

## 验证

### 1. DS 跑在期望节点

```bash
kubectl -n ingress-nginx get pod -l app.kubernetes.io/component=controller -o wide
# 期望:Pod 数 = 打标签节点数,且都 Running
```

### 2. 端口在 listen

```bash
# 模式 A(hostNetwork)— 每个入口节点上
ss -tlnp | grep -E ':80|:443|:8443'
# 应该看到 nginx 进程绑 :80 :443 :8443

# 模式 A 集群外打
for ip in 172.16.150.129 172.16.150.130; do
  echo "== $ip =="
  curl -sI -m 3 http://$ip:80
done
# 期望: 每个都 404 Not Found(controller 在 listen 但没 Ingress 规则匹配)
```

### 3. 模式 B 的 LB IP 分配 + ECMP

```bash
# LB IP 已分配
kubectl get svc -n ingress-nginx ingress-nginx-controller
# 期望: EXTERNAL-IP = 172.16.150.200

# 路由器侧:同 prefix 多 nexthop = ECMP 生效
# (在 FRR 容器 / 路由器上跑)
ip route show 172.16.150.200/32
# 期望:
#   nexthop via 172.16.150.129 dev eth0 weight 1
#   nexthop via 172.16.150.130 dev eth0 weight 1

# 集群外打 LB IP
curl -I http://172.16.150.200:80
```

### 4. 端到端 + 流量分布

```bash
# 端到端测试(部署 demo app → Ingress → 业务 Pod 四层都通)
bash test.sh

# 多发请求看流量是否散到多 ingress Pod(验证 ECMP)
for i in {1..20}; do
  curl -s -H "Host: <your-ingress-host>" http://172.16.150.200/ > /dev/null
done
kubectl -n ingress-nginx logs ds/ingress-nginx-controller --tail=100 \
  | awk '{print $1}' | sort -u   # 看到多个 source IP / Pod 才算均衡
```

---

## 踩坑

| 现象 | 模式 | 原因 | 修法 |
|---|---|---|---|
| Pod 起来但 `connection refused` | A | `dnsPolicy` 没改成 `ClusterFirstWithHostNet`,被自动降级成 `Default` | `kubectl set` 或改 deploy.yaml,参考 [deploy-guide.md](deploy-guide.md) |
| 端口 80/443 起不来 | A | 节点上已有 nginx/apache 占了 | `ss -tlnp \| grep :80` 找占用进程,停了或换节点 |
| `EXTERNAL-IP` 一直 `<pending>` | B | `lb-assigner` 没跑 / LB CIDR 池满 | `kubectl -n kube-system logs deploy/lb-assigner`;池容量检查 |
| 路由器只 1 个 nexthop(ECMP 没生效) | B | 路由器没开 ECMP / 只 1 个节点宣告 | FRR: `bgp bestpath as-path multipath-relax` + `maximum-paths`;`externalTrafficPolicy: Local` + 多节点跑 DS |
| 流量全到一个节点 | B | 路由器哈希是 L3(默认 src_ip),压测单源时全到一个 nexthop | Linux: `sysctl -w net.ipv4.fib_multipath_hash_policy=1` 改 L3+L4 |
| admission webhook 报 `no endpoints available` | A/B | 卸载残留 webhook 配置,backend 已死 | `k8s-cleanup-stuck` skill 详述,清残留 webhook |
| ns 卡 Terminating | A/B | finalizer 卡住 | 见 `k8s-cleanup-stuck` skill 或 [uninstall.sh](uninstall.sh) 已自动剥 |

---

## 何时用哪种模式

| 场景 | 选哪个 |
|---|---|
| 单机房 / 内网 / 自己控制 DNS,客户端少 | **A. hostNetwork**(简单,DNS 轮询节点 IP) |
| 业务要单一稳定 VIP / 跨节点高可用 / 配 Calico BGP | **B. BGP-LB + ECMP**(本仓库生产推荐) |
| 公有云(自带云 LB) | 用云 LB,Service 类型 LoadBalancer,云上自动分配 |
| K3s / 测试环境单节点 | hostNetwork + 改 Deployment(单副本即可)|
