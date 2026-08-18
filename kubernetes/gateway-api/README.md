# Gateway API

Kubernetes 新一代流量入口标准(`GatewayClass` / `Gateway` / `Route`),Ingress 的继承者。

> 状态: 学习笔记
> 常用 YAML 直接在 [examples/](examples/) 里挑着抄。

---

## 1. 是什么 / 为什么用它

| 维度 | Ingress | Gateway API |
|---|---|---|
| 规范定义方 | K8s 只定义 `Ingress` 字段,行为靠各实现 annotation 泛滥 | SIG-Network 统一规范,实现必须遵循 status/condition 契约 |
| 多团队隔离 | 一个 Ingress 全局共享,没法细粒度授权 | **Gateway(平台团队建)+ Route(业务团队建)** 分离 |
| 跨 namespace | 能力弱 | `parentRefs` + `ReferenceGrant` 原生支持 |
| 流量能力(重试/超时/灰度/镜像) | annotation 字符串,无类型检查 | `matches` / `filters` / `backendRefs.weight` 结构化字段 |
| 协议 | HTTP/HTTPS | HTTP / GRPC / TLS / TCP / UDP 统一 |
| 同域名多路由合并 | 多个 Ingress 冲突难排查 | 多个 HTTPRoute 自动 merge,权重相加 |

## 2. 核心概念(3 层)

```
┌──────────────┐  绑定   ┌─────────────┐  parentRefs  ┌──────────────┐
│ GatewayClass │ ──────▶ │   Gateway   │ ◀─────────── │   HTTPRoute  │
│   (控制器)    │         │  (监听端口)  │    挂载路由    │  (业务规则)   │
└──────────────┘         └─────────────┘              └──────┬───────┘
                                                   backendRefs │
                                                      ┌───────▼───────┐
                                                      │ Service / Pod │
                                                      └───────────────┘
```

- **GatewayClass**: 集群级,声明"用哪个控制器",类似 StorageClass。`kubectl get gatewayclass` 查看。
- **Gateway**: 入口,声明监听端口 / 协议 / TLS / 允许哪些 namespace 路由接入。**平台团队创建**。
- **Route**(HTTPRoute / GRPCRoute / TLSRoute / TCPRoute / UDPRoute): 业务规则,声明"域名 + 路径 → 哪个 Service"。**业务团队创建**,用 `parentRefs` 挂到 Gateway。

### 术语速查

| 术语 | 含义 | 例子 |
|---|---|---|
| `gatewayClassName` | 指定控制器 | `nginx` |
| `parentRefs[].sectionName` | 挂到 Gateway 的哪个 listener | `https` / `http` |
| `allowedRoutes` | 允许哪些 namespace 的路由接入 | `from: All` / `Same` / `Selector` |
| `ReferenceGrant` | 显式授权跨 namespace 引用(Service/Secret) | backend 在别的 ns 时需要 |
| `matches` | 匹配条件(host/path/header/query/method),同一条内 AND,数组间 OR | 类似 ingress `location` 条件 |
| `filters` | 请求改写(URLRewrite / Header / Redirect / Mirror) | 类似 ingress annotations |
| `backendRefs[].weight` | 权重分流(灰度) | 90/10 |
| `timeouts` / `retry` | 超时 / 重试 —— 规则级内建字段(v1.1+),不是 annotation | `request: 30s` |

## 3. 安装

### 3.1 装 CRD(每集群一次)

```bash
# 最新 stable: v1.5.x(2026-04)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/standard-install.yaml

# 需要 TCPRoute / UDPRoute / TLSRoute(实验通道)才装这个:
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.0/experimental-install.yaml
```

> 💡 公网 github 拉不动 → 按 `infra-url-rewrite` skill 把 URL 改走 Nexus raw / chfs 后再 apply。

### 3.2 装控制器(实现)

| 实现 | 适合 | GatewayClass | 说明 |
|---|---|---|---|
| **ingress-nginx**(v1.11+) | 已有 ingress-nginx,渐进迁移 | `nginx` | 实验性支持 Gateway API,需开 feature gate;功能子集(HTTPRoute) |
| **NGINX Gateway Fabric** | 要完整 Gateway API 能力 | `nginx` | 官方下一代控制器,纯 Gateway API 实现 |
| Envoy Gateway / Cilium / Traefik / APISIX | 各有取舍 | 各异 | 按需评估 |

**NGINX Gateway Fabric 安装**(内网 Nexus 改写,已验证文件路径):

```bash
# CRD(两个 tag 都是 deploy/crds.yaml)
kubectl apply -f https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/nginx/nginx-gateway-fabric/v2.6.7/deploy/crds.yaml
# 控制器(两个 tag 都是 deploy/default/deploy.yaml)
kubectl apply -f https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/nginx/nginx-gateway-fabric/v2.6.7/deploy/default/deploy.yaml
```

> ⚠ 注意:这两个文件是**仓库 raw 文件**,不是 release 资产 —— 官方文档里给的 `releases/download/vX.Y.Z/nginx-gateway.yaml` 是**404 不存在的**,照抄会失败。要降级就用 `v1.5.1` 替换 URL 里的 `v2.6.7`,路径结构相同。

ingress-nginx 开启方式(给 controller 容器加启动参数,具体以官方文档为准):

```bash
kubectl -n ingress-nginx set env deployment/ingress-nginx-controller \
  --containers=controller ENABLE_GATEWAY_API=true
# 或 controller args 里加 --enable-gateway-api,重启后 kubectl get gatewayclass 应能看到 nginx
```

> ⚠ ingress-nginx 的 Gateway API 是 **experimental 且功能子集**(主要 HTTPRoute)。生产建议评估 NGINX Gateway Fabric / Envoy Gateway。

## 4. 常用模式索引(→ examples/)

| # | 场景 | 文件 |
|---|---|---|
| 1 | Gateway 两种形态:单域名 / 通配符共享 | [examples/01-gateway.yaml](examples/01-gateway.yaml) |
| 2 | 最简 HTTPRoute(入门) | [examples/02-httproute-basic.yaml](examples/02-httproute-basic.yaml) |
| 3 | 多团队共享一个通配符 Gateway(跨 namespace) | [examples/03-httproute-multi-team.yaml](examples/03-httproute-multi-team.yaml) |
| 4 | 多路径 rewrite,替代 ingress-nginx `/api(/|$)(.*) → /$2` | [examples/04-httproute-multi-path.yaml](examples/04-httproute-multi-path.yaml) |
| 5 | 请求匹配(header/query/method)+ 金丝雀灰度 | [examples/05-httproute-matches-canary.yaml](examples/05-httproute-matches-canary.yaml) |
| 6 | 请求过滤:超时 / 重试 / 改 header / 镜像 | [examples/06-httproute-filters.yaml](examples/06-httproute-filters.yaml) |
| 7 | TLS 终止 + cert-manager + HTTP→HTTPS 跳转 | [examples/07-httproute-tls.yaml](examples/07-httproute-tls.yaml) |
| 8 | GRPCRoute | [examples/08-route-grpc.yaml](examples/08-route-grpc.yaml) |
| 9 | 四层 TCPRoute / TLSRoute / UDPRoute | [examples/09-route-layer4.yaml](examples/09-route-layer4.yaml) |

## 5. 快速验证

```bash
# CRD / 控制器就绪
kubectl get gatewayclass

# Gateway 状态(没 Accepted/Programmed 先查这里)
kubectl get gateway -A
kubectl describe gateway shared-gateway

# 路由是否 Accepted 到 Gateway
kubectl get httproute -A
kubectl describe httproute multi-path-route
```

网关入口地址看 Gateway 的 `status.addresses`(BGP-LB 分配或 node IP)。

## 6. 踩坑

| 坑 | 原因 / 解决 |
|---|---|
| 路由 `Accepted=False` | ① Gateway 没 ready ② listener 协议/端口不匹配 ③ `sectionName` 写错 ④ CRD 没装(API 404) |
| 跨 ns 引 Service 不通 | 缺 ReferenceGrant。**ReferenceGrant 建在 Service 所在 namespace**,`from` 写 HTTPRoute 的 namespace |
| hostname 不在通配符范围内 | listener `hostname: "*.example.com"` 只接受范围内 hostname,精确域名要能匹配上 |
| 同域名多路由互相覆盖 | 多个 HTTPRoute 会 merge,权重相加;检查有没有冲突的 `matches` |
| `URLRewrite` 不生效 | `ReplacePrefixMatch` 只替换前缀,等价 ingress `rewrite-target: /$1`;要整段替换用 `ReplaceFullPath` |
| GRPC/TCP 路由没反应 | 该类在实验通道,确认装 `experimental-install.yaml`,且实现支持该 kind |

## 7. 与 ingress-nginx 对应关系(迁移速查)

| ingress-nginx annotation | Gateway API 等价物 |
|---|---|
| `rewrite-target: /$2` | `filters[].urlRewrite.path.replacePrefixMatch` |
| `ssl-redirect: "true"` | `filters[].requestRedirect (scheme: https)` |
| `canary` / `canary-weight` | `backendRefs[].weight` + `matches[].headers` |
| `proxy-read-timeout` / `proxy-send-timeout` | `rules[].timeouts` |
| `proxy-next-upstream` | `rules[].retry` |
| `mirror-host` / `mirror-*` | `filters[].requestMirror` |
| `server-snippet` / `configuration-snippet` | ❌ 无直接等价(部分实现用 backendPolicy) |
