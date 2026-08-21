# Gateway API

Kubernetes 新一代流量入口标准(`GatewayClass` / `Gateway` / `Route`),Ingress 的继承者。

> 状态: 学习笔记
> 常用 YAML 直接在 [examples/](examples/) 里挑着抄。

---

## 1. 是什么 / 为什么用它

| 维度                          | Ingress                                                 | Gateway API                                                   |
| ----------------------------- | ------------------------------------------------------- | ------------------------------------------------------------- |
| 规范定义方                    | K8s 只定义`Ingress` 字段,行为靠各实现 annotation 泛滥 | SIG-Network 统一规范,实现必须遵循 status/condition 契约       |
| 多团队隔离                    | 一个 Ingress 全局共享,没法细粒度授权                    | **Gateway(平台团队建)+ Route(业务团队建)** 分离         |
| 跨 namespace                  | 能力弱                                                  | `parentRefs` + `ReferenceGrant` 原生支持                  |
| 流量能力(重试/超时/灰度/镜像) | annotation 字符串,无类型检查                            | `matches` / `filters` / `backendRefs.weight` 结构化字段 |
| 协议                          | HTTP/HTTPS                                              | HTTP / GRPC / TLS / TCP / UDP 统一                            |
| 同域名多路由合并              | 多个 Ingress 冲突难排查                                 | 多个 HTTPRoute 自动 merge,权重相加                            |

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

| 术语                         | 含义                                                           | 例子                                    |
| ---------------------------- | -------------------------------------------------------------- | --------------------------------------- |
| `gatewayClassName`         | 指定控制器                                                     | `nginx`                               |
| `parentRefs[].sectionName` | 挂到 Gateway 的哪个 listener                                   | `https` / `http`                    |
| `allowedRoutes`            | 允许哪些 namespace 的路由接入                                  | `from: All` / `Same` / `Selector` |
| `ReferenceGrant`           | 显式授权跨 namespace 引用(Service/Secret)                      | backend 在别的 ns 时需要                |
| `matches`                  | 匹配条件(host/path/header/query/method),同一条内 AND,数组间 OR | 类似 ingress`location` 条件           |
| `filters`                  | 请求改写(URLRewrite / Header / Redirect / Mirror)              | 类似 ingress annotations                |
| `backendRefs[].weight`     | 权重分流(灰度)                                                 | 90/10                                   |
| `timeouts` / `retry`     | 超时 / 重试 —— 规则级内建字段(v1.1+),不是 annotation         | `request: 30s`                        |

## 3. 安装 / 卸载

### 3.1 一键脚本(推荐)

```bash
# 安装 standard CRD + NGINX Gateway Fabric
bash kubernetes/gateway-api/install.sh

# 需要实验通道(TCPRoute / UDPRoute / TLSRoute / GRPCRoute)
bash kubernetes/gateway-api/install.sh --experimental

# 只装 CRD,先不装控制器
bash kubernetes/gateway-api/install.sh --skip-ngf
```

卸载:

```bash
# 默认 dry-run
bash kubernetes/gateway-api/uninstall.sh

# 真删 NGF + standard CRD
bash kubernetes/gateway-api/uninstall.sh --apply

# 只卸载 NGF,保留 Gateway API CRD
bash kubernetes/gateway-api/uninstall.sh --apply --keep-crds
```

### 3.2 手工装 CRD(每集群一次)

```bash
# 示例版本 v1.4.0 —— 走内网 Nexus(github release → raw-github 代理)
kubectl apply -f https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
# 需要 TCPRoute / UDPRoute / TLSRoute(实验通道)才装这个:
kubectl apply -f https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/kubernetes-sigs/gateway-api/releases/download/v1.4.0/experimental-install.yaml
```

> Nexus 仓库映射:`raw-github` = `github.com` 全站(release 下载走它);`raw-githubusercontent` = `raw.githubusercontent.com`(仓库 raw 文件)。这两个文件是 **release 资产**,仓库里没有合并的 install.yaml(`config/crd/standard|experimental/` 只有单个 CRD 文件),所以不走 raw-githubusercontent。

### 3.3 手工装控制器(实现)

| 实现                                      | 适合                        | GatewayClass | 说明                                                         |
| ----------------------------------------- | --------------------------- | ------------ | ------------------------------------------------------------ |
| **ingress-nginx**(v1.11+)           | 已有 ingress-nginx,渐进迁移 | `nginx`    | 实验性支持 Gateway API,需开 feature gate;功能子集(HTTPRoute) |
| **NGINX Gateway Fabric**            | 要完整 Gateway API 能力     | `nginx`    | 官方下一代控制器,纯 Gateway API 实现                         |
| Envoy Gateway / Cilium / Traefik / APISIX | 各有取舍                    | 各异         | 按需评估                                                     |

**NGINX Gateway Fabric 安装**(内网 Nexus 改写,已验证文件路径):

```bash
# CRD(这些 CRD 较大,用 server-side apply 避免 last-applied 注解超长)
kubectl apply --server-side -f https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/nginx/nginx-gateway-fabric/v2.4.2/deploy/crds.yaml
# 控制器(两个 tag 都是 deploy/default/deploy.yaml)
kubectl apply -f https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/nginx/nginx-gateway-fabric/v2.4.2/deploy/default/deploy.yaml
```

> ⚠ 注意:这两个文件是**仓库 raw 文件**,不是 release 资产 —— 官方文档里给的 `releases/download/vX.Y.Z/nginx-gateway.yaml` 是**404 不存在的**,照抄会失败。要降级就用 `v1.5.1` 替换 URL 里的 `v2.4.2`,路径结构相同。

**Helm 安装**(这条最小安装命令已验证):

```bash
helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version 2.4.2 \
  --create-namespace -n nginx-gateway \
  --wait
```

**Helm 安装 + 数据面 DS 模式**(与 ingress-nginx DS+hostNetwork 对齐):

```bash
helm upgrade --install ngf oci://ghcr.io/nginx/charts/nginx-gateway-fabric \
  --version 2.4.2 \
  --create-namespace -n nginx-gateway \
  --set nginx.kind=daemonSet \
  --set-string nginx.pod.nodeSelector."node-role\.kubernetes\.io/edge"=true \
  --wait
```

- **控制面永远是 Deployment**(`nginxGateway.kind` 只支持 deployment);`nginx.kind=daemonSet` 让**数据面**每节点一个 NGINX pod(NGF 经 NginxProxy CR 动态创建,chart 里没有直接的 DaemonSet 资源)。
- **kubectl 方式只有 Deployment** —— 要 DS 模式必须 Helm(或 kubectl apply 后手改 CR)。
- 数据面 Service 默认 `LoadBalancer + externalTrafficPolicy: Local`(本集群 Calico BGP-LB 自动分 IP);要 NodePort 加 `--set nginx.service.type=NodePort`。
- 镜像 `ghcr.io/nginx/nginx-gateway-fabric*` 走节点 containerd mirror(ghcr → ghcr.ihome.sxxpqp.top:8443),无需改 image。
- 集群 K8s 需 **≥ 1.31**(chart `kubeVersion` 约束,装前 `kubectl get nodes` 确认)。
- ⚠ 本机 helm 若报 `docker-credential-desktop not found`(Docker Desktop credsStore 干扰):`DOCKER_CONFIG=<空目录>` 再跑。

ingress-nginx 开启方式(给 controller 容器加启动参数,具体以官方文档为准):

```bash
kubectl -n ingress-nginx set env deployment/ingress-nginx-controller \
  --containers=controller ENABLE_GATEWAY_API=true
# 或 controller args 里加 --enable-gateway-api,重启后 kubectl get gatewayclass 应能看到 nginx
```

> ⚠ ingress-nginx 的 Gateway API 是 **experimental 且功能子集**(主要 HTTPRoute)。生产建议评估 NGINX Gateway Fabric / Envoy Gateway。

## 4. 常用模式索引(→ examples/)

| # | 场景                                       | 文件                                                                                  |
| - | ------------------------------------------ | ------------------------------------------------------------------------------------- |
| 1 | Gateway 两种形态:单域名 / 通配符共享       | [examples/01-gateway.yaml](examples/01-gateway.yaml)                                   |
| 2 | 最简 HTTPRoute(入门)                       | [examples/02-httproute-basic.yaml](examples/02-httproute-basic.yaml)                   |
| 3 | 多团队共享一个通配符 Gateway(跨 namespace) | [examples/03-httproute-multi-team.yaml](examples/03-httproute-multi-team.yaml)         |
| 4 | 多路径 rewrite,替代 ingress-nginx `/api(/  | $)(.*) → /$2`                                                                        |
| 5 | 请求匹配(header/query/method)+ 金丝雀灰度  | [examples/05-httproute-matches-canary.yaml](examples/05-httproute-matches-canary.yaml) |
| 6 | 请求过滤:超时 / 重试 / 改 header / 镜像    | [examples/06-httproute-filters.yaml](examples/06-httproute-filters.yaml)               |
| 7 | TLS 终止 + cert-manager + HTTP→HTTPS 跳转 | [examples/07-httproute-tls.yaml](examples/07-httproute-tls.yaml)                       |
| 8 | GRPCRoute                                  | [examples/08-route-grpc.yaml](examples/08-route-grpc.yaml)                             |
| 9 | 四层 TCPRoute / TLSRoute / UDPRoute        | [examples/09-route-layer4.yaml](examples/09-route-layer4.yaml)                         |

## 5. 快速验证

```bash
# CRD / 控制器就绪
kubectl get gatewayclass
kubectl -n nginx-gateway get pods -o wide

# Gateway 状态(没 Accepted/Programmed 先查这里)
kubectl get gateway -A
kubectl describe gateway shared-gateway

# 路由是否 Accepted 到 Gateway
kubectl get httproute -A
kubectl describe httproute multi-path-route
```

网关入口地址看 Gateway 的 `status.addresses`(BGP-LB 分配或 node IP)。

## 6. 踩坑

| 坑                        | 原因 / 解决                                                                                                |
| ------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 路由`Accepted=False`    | ① Gateway 没 ready ② listener 协议/端口不匹配 ③`sectionName` 写错 ④ CRD 没装(API 404)                |
| 跨 ns 引 Service 不通     | 缺 ReferenceGrant。**ReferenceGrant 建在 Service 所在 namespace**,`from` 写 HTTPRoute 的 namespace |
| hostname 不在通配符范围内 | listener`hostname: "*.example.com"` 只接受范围内 hostname,精确域名要能匹配上                             |
| 同域名多路由互相覆盖      | 多个 HTTPRoute 会 merge,权重相加;检查有没有冲突的`matches`                                               |
| `URLRewrite` 不生效     | `ReplacePrefixMatch` 只替换前缀,等价 ingress `rewrite-target: /$1`;要整段替换用 `ReplaceFullPath`    |
| GRPC/TCP 路由没反应       | 该类在实验通道,确认装`experimental-install.yaml`,且实现支持该 kind                                       |

## 7. 与 ingress-nginx 对应关系(迁移速查)

| ingress-nginx annotation                        | Gateway API 等价物                               |
| ----------------------------------------------- | ------------------------------------------------ |
| `rewrite-target: /$2`                         | `filters[].urlRewrite.path.replacePrefixMatch` |
| `ssl-redirect: "true"`                        | `filters[].requestRedirect (scheme: https)`    |
| `canary` / `canary-weight`                  | `backendRefs[].weight` + `matches[].headers` |
| `proxy-read-timeout` / `proxy-send-timeout` | `rules[].timeouts`                             |
| `proxy-next-upstream`                         | `rules[].retry`                                |
| `mirror-host` / `mirror-*`                  | `filters[].requestMirror`                      |
| `server-snippet` / `configuration-snippet`  | ❌ 无直接等价(部分实现用 backendPolicy)          |
