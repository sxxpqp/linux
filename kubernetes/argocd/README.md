# ArgoCD v2.13.3 — K8s 1.28 GitOps 部署

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/argocd/README.md
> 状态: 学习笔记(YAML 已落盘,未在 K8s 1.28 集群跑全流程验证)

裸金属 GitOps 控制面。**为什么选 v2.13.3** —— K8s 1.28 集群下 ArgoCD **唯一**官方背书的"最新可用"版本:

- v2.13 是覆盖 K8s 1.28 的**最后一个** ArgoCD minor(再往上 v2.14 起步就是 K8s 1.29)
- v2.13 还在维护(patch 持续出),v2.13.3 是当前选定的固定 tag
- v3.x 全部不在 K8s 1.28 兼容矩阵里(v3.0+ 起步是 1.30),装上去能跑但出问题没人管

## 版本兼容速查

| ArgoCD | K8s 支持窗口 | 用法 |
|---|---|---|
| v3.4.x | 1.32 - 1.34 | 等集群升 1.32+ |
| v3.3.x | 1.31 - 1.33 | 等集群升 1.31+(留了一份 [arglcdinstall.yaml](arglcdinstall.yaml) 当参考) |
| v3.0.x | 1.30 - 1.32 | 等集群升 1.30+ |
| v2.14.x | 1.29 - 1.31 | 等集群升 1.29 后过渡 |
| **v2.13.x**(本目录默认) | **1.28 - 1.31** | **当前 K8s 1.28 用这个** |
| v2.12.x | 1.27 - 1.30 | 老集群 |

> ⚠ 上面的兼容窗口是凭印象给的,**生产部署前请核对** https://argo-cd.readthedocs.io/en/stable/operator-manual/tested-kubernetes-versions/

## 升级路径

```
现在: K8s 1.28 + ArgoCD v2.13.3        ← 当前
                ↓ 集群升 1.29
K8s 1.29 + ArgoCD v2.13.x / v2.14.x   ← 1.29 是重叠点,平滑过渡
                ↓ 集群升 1.30
K8s 1.30 + ArgoCD v3.0.x              ← 这时才碰 v3
                ↓ 集群升 1.31+
K8s 1.31 + ArgoCD v3.1+               ← arglcdinstall.yaml(v3.3.0)派上用场
```

---

## TL;DR

```bash
# 1. 安装
kubectl create namespace argocd
kubectl apply -n argocd -f kubernetes/argocd/install-v2.13.3.yaml

# 2. 等所有组件 ready(6 个 Deploy + 1 个 StatefulSet)
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
kubectl -n argocd wait --for=condition=available deploy --all --timeout=300s

# 3. 拿初始 admin 密码(一次性,登完应改掉)
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# 4. 本地访问 UI(开发 / 临时用)
kubectl -n argocd port-forward svc/argocd-server 8080:443
# 浏览器: https://localhost:8080  用户 admin / 上面那个密码
```

生产暴露走 Ingress / LoadBalancer,见下面 [访问方式](#访问方式) 段。

---

## 组件清单(7 个核心)

| 组件 | kind | 副本 | 镜像 | 作用 |
|---|---|---|---|---|
| `argocd-server` | Deployment | 1 | `quay.io/argoproj/argocd:v2.13.3` | API + UI(gRPC + HTTP,默认 `:443` ClusterIP) |
| `argocd-application-controller` | **StatefulSet** | 1 | `quay.io/argoproj/argocd:v2.13.3` | 核心 reconcile loop:监听 Application CR,跟集群 diff |
| `argocd-repo-server` | Deployment | 1 | `quay.io/argoproj/argocd:v2.13.3` | 拉 git / Helm / Kustomize,产生 manifest |
| `argocd-applicationset-controller` | Deployment | 1 | `quay.io/argoproj/argocd:v2.13.3` | ApplicationSet(批量生成 Application) |
| `argocd-notifications-controller` | Deployment | 1 | `quay.io/argoproj/argocd:v2.13.3` | 同步状态变更 → 通知(Slack / 邮件 / webhook) |
| `argocd-dex-server` | Deployment | 1 | `ghcr.io/dexidp/dex:v2.41.1` | OIDC / SAML / LDAP 接入(不接 SSO 时空转) |
| `argocd-redis` | Deployment | **1(非 HA)** | `redis:7.0.15-alpine` | controller / server 共享缓存 |

**3 个镜像源走仓库已配 mirror,YAML 一个字不改**:

| 镜像源 | mirror | 配置位置 |
|---|---|---|
| `quay.io` | `quay.ihome.sxxpqp.top:8443` | `/etc/containerd/certs.d/quay.io/hosts.toml` |
| `ghcr.io` | `ghcr.ihome.sxxpqp.top:8443` | `/etc/containerd/certs.d/ghcr.io/hosts.toml` |
| `docker.io` | `dockerhub.ihome.sxxpqp.top:8443` | `/etc/containerd/certs.d/docker.io/hosts.toml` |

没配 mirror 的节点先跑 `bash docker/containerd/mirrors.sh`(详见顶层 [CLAUDE.md](../../CLAUDE.md))。

> **非 HA 提醒**:单 redis、单 controller。生产高可用要换 `manifests/ha/install.yaml`(redis-ha + 多副本 controller / server / repo-server)。当前这份适合**测试 / 内部 / 单集群 GitOps**。

---

## 文件

| 文件 | 状态 | 说明 |
|---|---|---|
| [install-v2.13.3.yaml](install-v2.13.3.yaml) | ✅ 默认 | **ArgoCD v2.13.3 完整 manifest**(CRD + RBAC + 7 组件,~24000 行)。K8s 1.28 用这个 |
| [arglcdinstall.yaml](arglcdinstall.yaml) | 🟡 暂留 | 历史下载的 v3.3.0 manifest。**K8s 1.28 不要用**,留到集群升 1.31+ 后作参考。文件名拼错了(应为 `argocdinstall.yaml`),暂不动 |

> 目前**没有 install.sh / uninstall.sh / test.sh**。需要按本仓库 calico / ingress-nginx 的风格补一套?

---

## 前置

### 1. K8s 1.28 集群 + kubectl 可用

```bash
kubectl version --short
# Server: v1.28.x  ← 1.28 任一小版本都在 v2.13.x 兼容窗口里
```

### 2. 节点 containerd 已配 mirror(已是本仓库默认)

```bash
# 验证 3 个 mirror 都在
for h in quay.io ghcr.io docker.io; do
  echo "== $h =="
  cat /etc/containerd/certs.d/$h/hosts.toml
done
```

没配的节点先跑 `bash docker/containerd/mirrors.sh` + `systemctl restart containerd`。**YAML 里 `image:` 字段一个字不改**,kubelet 自动走 mirror。

### 3. 命名空间

```bash
kubectl create namespace argocd
```

ArgoCD 默认所有资源都装在 `argocd` ns;改 ns 需要同时改 RBAC,不建议。

---

## 安装

```bash
kubectl apply -n argocd -f kubernetes/argocd/install-v2.13.3.yaml
```

等所有组件 ready(冷启动大概 1-3 分钟,取决于拉镜像速度):

```bash
# StatefulSet
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# 6 个 Deployment
kubectl -n argocd wait --for=condition=available deploy --all --timeout=300s

# Pod 全 Running
kubectl -n argocd get pod
# 期望:
# argocd-application-controller-0           1/1   Running
# argocd-applicationset-controller-xxx      1/1   Running
# argocd-dex-server-xxx                     1/1   Running
# argocd-notifications-controller-xxx       1/1   Running
# argocd-redis-xxx                          1/1   Running
# argocd-repo-server-xxx                    1/1   Running
# argocd-server-xxx                         1/1   Running
```

---

## 拿初始 admin 密码

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

> 这个 Secret 是 `argocd-server` 启动时**自动生成一次性密码**写进去的。**登进去后第一件事:改密码 + 删掉这个 Secret**,否则任何能读 ns 的人都能拿到:
>
> ```bash
> # 登进去改完密码后
> kubectl -n argocd delete secret argocd-initial-admin-secret
> ```

---

## 访问方式

`argocd-server` Service 默认 ClusterIP `:443`(里面是自签 TLS)。生产 4 种暴露方式按场景选:

| 模式 | 适用 | 命令 / 配置 |
|---|---|---|
| **A. port-forward** | 临时调试 / 单人用 | `kubectl -n argocd port-forward svc/argocd-server 8080:443` → `https://localhost:8080` |
| **B. NodePort** | 内网快速暴露 | `kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"NodePort"}}'`,然后 `kubectl -n argocd get svc argocd-server` 看端口 |
| **C. LoadBalancer**(本仓库 Calico BGP-LB) | 生产 | `kubectl -n argocd patch svc argocd-server -p '{"spec":{"type":"LoadBalancer"}}'`,LB IP 从 `172.16.150.200/29` 池里出 |
| **D. Ingress + TLS**(推荐生产) | 已有 ingress-nginx | 见下面 Ingress 示例 |

### 模式 D:Ingress 暴露(配合本仓库 ingress-nginx)

ArgoCD server 后端是 HTTPS + gRPC,Ingress 必须配 SSL passthrough 或 backend-protocol HTTPS,二选一:

```yaml
# 方案 D1: backend-protocol HTTPS(推荐,Ingress 在 TLS 终止后转 HTTPS 给 server)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
  - host: argocd.ihome.sxxpqp.top
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
  tls:
  - hosts:
    - argocd.ihome.sxxpqp.top
    secretName: argocd-server-tls   # 自己签 / cert-manager 签
```

> ⚠ **gRPC + CLI 兼容性**:`argocd` CLI 默认走 gRPC,模式 D1 在 ingress-nginx + HTTP/2 下基本 OK。如果 CLI 报 `transport is closing`,改成 SSL passthrough(D2):
>
> ```yaml
> annotations:
>   nginx.ingress.kubernetes.io/ssl-passthrough: "true"
> ```
>
> SSL passthrough 需要 ingress-nginx **启动参数加 `--enable-ssl-passthrough`**,本仓库默认没开,要开见 [ingress-nginx/deploy-guide.md](../ingress-nginx/deploy-guide.md)。

---

## 装 argocd CLI

> CLI 版本要跟 server 一致或低半个版本,装 v2.13.3 配套的 CLI。

```bash
# Linux amd64(走 chfs,公网慢)
curl -fsSL https://chfs.sxxpqp.top:8443/chfs/shared/k8s/argocd/argocd-linux-amd64-v2.13.3 \
  -o /usr/local/bin/argocd
# 公网备用:
# curl -fsSL https://github.com/argoproj/argo-cd/releases/download/v2.13.3/argocd-linux-amd64 \
#   -o /usr/local/bin/argocd
chmod +x /usr/local/bin/argocd
argocd version --client

# 登录(port-forward 场景)
argocd login localhost:8080 --username admin --insecure
# 登录(Ingress 场景)
argocd login argocd.ihome.sxxpqp.top --username admin --grpc-web
```

> `--grpc-web` 是给 Ingress 不开 ssl-passthrough 场景用的。

---

## 第一个 Application

```bash
# 方法 1: CLI
argocd app create guestbook \
  --repo https://github.com/argoproj/argocd-example-apps.git \
  --path guestbook \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default \
  --sync-policy auto

# 方法 2: 声明式 YAML
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# 状态
argocd app get guestbook
argocd app sync guestbook   # 手动 sync
```

> **公网 git repo 在内网集群拉不动**怎么办:把 repo 推到内部 GitLab / Gitea,Application 的 `repoURL` 换成内部地址;或者给 ArgoCD 配 HTTPS proxy(`argocd-cm` ConfigMap 里加 `repo.proxy`),不是改 YAML image。

---

## 验证

### 1. 组件全 Running

```bash
kubectl -n argocd get pod
# 7 个 Pod,全部 1/1 Running
```

### 2. CRD 装上了

```bash
kubectl get crd | grep argoproj.io
# 应该有:
# applications.argoproj.io
# applicationsets.argoproj.io
# appprojects.argoproj.io
```

### 3. UI / API 能登

```bash
# port-forward + 浏览器登一下,或者
argocd login localhost:8080 --username admin --insecure
argocd cluster list
# 期望:有一行 in-cluster, STATUS=Successful
```

### 4. 第一个 app 能 sync

```bash
argocd app sync guestbook
kubectl get pod -n default | grep guestbook
# 期望: Pod 跑起来
```

---

## 常见踩坑

| 现象 | 原因 | 修法 |
|---|---|---|
| Pod 卡 `ImagePullBackOff`,镜像 `quay.io/argoproj/argocd:v2.13.3` 或 `ghcr.io/dexidp/dex:v2.41.1` | 节点 containerd 没配对应 mirror | `bash docker/containerd/mirrors.sh` + `systemctl restart containerd`,**别改 YAML image** |
| CRD apply 报 `field is immutable` | 之前装过别的版本(尤其 v3.x → v2.x 降级),CRD 字段冲突 | `kubectl get crd | grep argoproj.io` 确认版本;先 `kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io`(**会连带删 Application CR,确认没生产 app 再删**) |
| `argocd-server` 起来但 UI 502 | `argocd-repo-server` / `redis` 没 ready | `kubectl -n argocd get pod` 排查,redis 没起 server 直接挂 |
| `argocd login` 报 `connection refused` | port-forward 没起 / Ingress 没配 backend-protocol HTTPS | 见上面 [访问方式](#访问方式) D 段 |
| `argocd login` 报 `transport is closing` / `code = Unavailable` | Ingress 跑 HTTP/2 但 gRPC 协商失败 | CLI 加 `--grpc-web`,或 Ingress 开 ssl-passthrough |
| Application 一直 `OutOfSync`,但 git 上没改动 | repo-server 缓存 / 仓库连不上(内网拉不动公网 git) | `kubectl -n argocd logs deploy/argocd-repo-server`,看是否 git clone 超时;换内部 repo |
| 应用 `Healthy` 但实际没起来 | ArgoCD 只看 K8s 资源状态,不看业务健康 | 加 `Application.spec.ignoreDifferences` 或自定义 health check |
| `argocd-redis` 重启 → controller / server 一起重启 | 单 redis 没 HA,redis 一抖动 controller 缓存全没 | 接受 / 换 `manifests/ha/install.yaml` |
| 升级版本后 CRD 字段消失 | ArgoCD 大版本升级偶尔删字段(v2 → v3 改了不少) | 升级前看 release notes 的 breaking change,不要直接 apply 新版 install.yaml |

---

## 卸载

```bash
# 1. 先删所有 Application(不然 finalizer 卡 ns)
kubectl get applications.argoproj.io -A -o name | xargs -I {} kubectl patch {} \
  --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl delete applications.argoproj.io --all -A

# 2. 删 install.yaml 里的所有资源
kubectl delete -f kubernetes/argocd/install-v2.13.3.yaml --ignore-not-found

# 3. 删 CRD(可选,留着不影响其它东西)
kubectl delete crd applications.argoproj.io applicationsets.argoproj.io appprojects.argoproj.io

# 4. 删 namespace
kubectl delete namespace argocd
```

> ns 卡 Terminating 见 `k8s-cleanup-stuck` skill(顶层 [CLAUDE.md](../../CLAUDE.md) 已列)。

---

## 升级 / 切版本

### 集群升 K8s 1.30+ 后,从 v2.13.3 → v3.x

```bash
# 1. 备份现有 Application
kubectl get applications.argoproj.io -A -o yaml > /tmp/argocd-apps-backup.yaml
kubectl get appprojects.argoproj.io -A -o yaml > /tmp/argocd-projects-backup.yaml

# 2. 用本目录预留的 arglcdinstall.yaml(v3.3.0)或拉更新的
kubectl diff -n argocd -f kubernetes/argocd/arglcdinstall.yaml

# 3. apply
kubectl apply -n argocd -f kubernetes/argocd/arglcdinstall.yaml

# 4. 等 rollout
kubectl -n argocd rollout status statefulset/argocd-application-controller
```

> **大版本 v2 → v3 的 breaking 点**(升级前必看):
>
> - CMP v1 移除,自定义 plugin 全部要重写成 sidecar 模式
> - Helm 2 移除
> - `argocd-cm` 里 `repositories:` key 废弃,改用 Secret
> - `exec` RBAC 默认 deny,UI Pod 终端要显式 grant
> - Server-side Apply 成默认,首次 sync 可能全是 OutOfSync(annotation 冲突)
> - dex 升大版本,OIDC connector 配置字段微调
>
> **强烈建议**:先在测试集群跑一遍 v2.13 → v3.x 升级,验证所有 Application 还能 sync,再上生产。

### 想钉 v2.13 内的更新 patch

```bash
# 看 v2.13 最新 patch
curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases | \
  grep '"tag_name"' | grep v2.13 | head -5

# 拉新 patch
curl -fsSL https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.X/manifests/install.yaml \
  -o install-v2.13.X.yaml

# diff 看变化
diff install-v2.13.3.yaml install-v2.13.X.yaml
```

---

## 相关

- 上游: https://github.com/argoproj/argo-cd
- 安装 manifest 源: https://github.com/argoproj/argo-cd/blob/v2.13.3/manifests/install.yaml
- 兼容矩阵: https://argo-cd.readthedocs.io/en/stable/operator-manual/tested-kubernetes-versions/
- 配套: [ingress-nginx](../ingress-nginx/) 暴露 UI / [calico/bgp-lb](../calico/bgp-lb/) 提供 LB IP
