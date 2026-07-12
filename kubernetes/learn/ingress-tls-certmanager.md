# Ingress TLS + cert-manager 实战

> 真实生产经验，2026-06-16 记录

## 一、cert-manager 发证流程

### HTTP-01 挑战（最常用）

```
Internet               K8s 集群
┌──────────┐    HTTP    ┌─────────────────────┐
│Let's      │◄─────────│ cert-manager pod      │
│Encrypt   │           │                      │
│(203.0.x.x)│           │ 1. 自动创建临时 Pod     │
└──────────┘           │ 2. 自动插入路由         │
                        │    /.well-known/...    │
                        │ 3. 验证通过后自动清理    │
                        └─────────────────────┘

要求：
  ✅ 80 端口公网可达
  ✅ 域名 DNS 指向公网 IP
```

**关键：你完全不用手动配 .well-known。** cert-manager 全自动：
- 自动创建临时 Pod 监听 `/.well-known/acme-challenge/xxx`
- 自动修改 Ingress 加一条路由
- Let's Encrypt 来验证
- 验证完自动清理

### DNS-01 挑战（不依赖 80/443）

```
Let's Encrypt → 要求 DNS 服务商加一条 TXT 记录
              → 查到了 → 发证书
              → 查不到 → 拒绝

要求：
  ✅ 有 DNS 服务商的 API Token（阿里云/腾讯云/DNSPod...）
  ❌ 不需要 80/443 端口开放
```

**适合内网、家庭实验室等没有公网端口的场景。**

---

## 二、HTTP-01 配置（公网环境）

### 2.1 部署 cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.0/cert-manager.yaml
```

### 2.2 配置 ClusterIssuer

```yaml
# cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com     # 改成你的邮箱
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        ingress:
          class: nginx
```

```bash
kubectl apply -f cluster-issuer.yaml
```

### 2.3 配置 Ingress 自动签发

```yaml
# ingress-tls.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-tls
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod  # 关联 Issuer
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - example.com
    secretName: example-tls           # 证书会自动存入这个 Secret
  rules:
  - host: example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: web-svc
```

```bash
kubectl apply -f ingress-tls.yaml
```

### 2.4 验证

```bash
# 查看证书状态
kubectl get certificate -A
kubectl describe certificate example-tls

# 查看 Secret（证书签发后自动生成）
kubectl get secret example-tls -o yaml
```

---

## 三、DNS-01 配置（内网/家庭实验室）

### 3.1 阿里云 DNS 示例

```yaml
# alidns-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: alidns-secret
  namespace: cert-manager
data:
  access-key: <base64 你的 AccessKey>
  secret-key: <base64 你的 AccessKeySecret>
```

```bash
# base64 编码
echo -n "你的AccessKey" | base64
echo -n "你的AccessKeySecret" | base64
kubectl apply -f alidns-secret.yaml
```

### 3.2 配置 DNS-01 ClusterIssuer

```yaml
# cluster-issuer-dns.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-dns-key
    solvers:
    - dns01:
        alidns:                        # 阿里云 DNS
          accessKeySecretRef:
            name: alidns-secret
            key: access-key
          secretKeySecretRef:
            name: alidns-secret
            key: secret-key
      # selector:                      # 可选：限制哪些域名走这个
      #   dnsNames:
      #   - '*.sxxpqp.top'
```

```bash
kubectl apply -f cluster-issuer-dns.yaml
```

### 3.3 Ingress 引用 DNS-01 Issuer

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example-tls
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-dns   # 改成指 DNS-01 Issuer
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - example.com
    secretName: example-tls
  rules:
  - host: example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: web-svc
```

---

## 四、内网/无公网 IP 场景

如果没有公网 IP 或 80/443 端口，直接用 DNS-01 方案，按上面阿里云 DNS-01 的配置即可，不需要暴露端口。

---

## 五、常用操作

```bash
# 查看已签发的证书
kubectl get certificate -A

# 查看证书详情
kubectl describe certificate <name> -n <namespace>

# 看签发日志
kubectl logs -n cert-manager deploy/cert-manager

# 强制续签（测试用）
kubectl delete certificate <name> -n <namespace>

# 查看 Secret（证书内容 base64 编码）
kubectl get secret <name> -n <namespace> -o yaml
```

## 六、常见问题

### Q：证书不签发，一直 Pending？
```bash
kubectl describe certificate -n <namespace> <name>
kubectl describe clusterissuer letsencrypt-prod
# 看 Events 里的错误信息
```

### Q：需要手动配 .well-known 吗？
**不需要。** cert-manager 自动创建临时 Pod 和路由，验证完自动清理。除非你用了 server-snippet 拦截了 `/.well-known`，才需要手动放行。

### Q：证书快到期会自动续吗？
**自动续。** cert-manager 在到期前 30 天自动走一遍同样的验证流程。

### Q：DNS-01 比 HTTP-01 好在哪？
| | HTTP-01 | DNS-01 |
|---|---|---|
| 需要公网 80/443 | ✅ 需要 | ❌ 不需要 |
| 内网能用 | ❌ 不行 | ✅ 可以 |
| 配置复杂度 | 低 | 中等（要配 DNS API） |
| 泛域名证书 | ❌ 不支持 | ✅ 支持 `*.sxxpqp.top` |

---

## 七、参考

- [cert-manager 官方文档](https://cert-manager.io/docs/)
- [cert-manager HTTP-01](https://cert-manager.io/docs/configuration/acme/http01/)
- [cert-manager DNS-01](https://cert-manager.io/docs/configuration/acme/dns01/)
