# Ingress 路径优先级 & 重写规则

> 真实生产经验总结，2026-06-16 记录

## 一、pathType 三种类型

| pathType | 含义 |
|---|---|
| `Exact` | 精准匹配，必须完全一致 |
| `Prefix` | 前缀匹配，以 `/` 分割的前缀 |
| `ImplementationSpecific` | 由 Ingress Controller 自己定义（Nginx = Prefix，Traefik/Kong 支持正则） |

## 二、优先级规则（一句话）

> **不同长度 → 长的赢；相同长度 → Exact > Prefix = ImplementationSpecific**

```
用户请求 /api/v3/order

Controller 内部排序（按 path 长度从长到短）：
  /api/v3/order  Exact(12)  ← 最长且完全匹配 → 胜出
  /api/v3        Prefix(8)  ← 匹配但长度更短
  /api           Prefix(4)  ← 匹配但更短
  /              Prefix(1)  ← 兜底，最短

特殊情况："/" Prefix 匹配一切，但永远排最后
         只做兜底路由用
```

## 三、多个 Ingress 自动合并

同一域名可以写在多个 Ingress 里，Controller 会自动合并路由表。

```yaml
# ingress-api.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-api
spec:
  rules:
  - host: example.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service: api-svc
---
# ingress-web.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-web
spec:
  rules:
  - host: example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: web-svc
```

**合并结果（Nginx 实测）：**
```
example.com → server block
  /api   → api-svc
  /      → web-svc
```

### ⚠️ 踩坑：路径冲突

不同 Ingress 配了相同的 path 指向不同 Service → Controller 行为不确定（Nginx 报警告，ALB 直接拒绝）。

## 四、Rewrite 为什么必须拆？

**rewrite-target 是作用于整个 Ingress 的 annotation，不是作用于某一条 path 的。**

```yaml
# ❌ 不要这样写在一个 Ingress 里
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2  # ← 全局生效！
spec:
  rules:
  - host: example.com
    http:
      paths:
      - path: /api(/|$)(.*)
        backend:
          service: api-svc
      - path: /
        backend:
          service: web-svc                # / 也被 rewrite-target 影响
```

```yaml
# ✅ 正确的做法：拆开 + 只在需要的 Ingress 上加 annotation
---
# ingress-api.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-api
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  rules:
  - host: example.com
    http:
      paths:
      - path: /api(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service: api-svc
---
# ingress-web.yaml（不加 rewrite，不影响 / 路由）
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-web
spec:
  rules:
  - host: example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: web-svc
```

**结果：** `/api/users` → rewrite 成 `/users` 进 api-svc；`/` 原样进 web-svc，互不影响。

## 五、生产建议

| 场景 | 写法 | 原因 |
|---|---|---|
| 小项目/单人维护 | 一个 Ingress | 省事 |
| 大项目/多团队 | 按功能/团队拆多个 Ingress | 各管各的，互不干扰 |
| 需要 rewrite | 必须拆 | rewrite-target 是全局 annotation |
| 不同 namespace 的 Service | 必须拆 | Ingress 默认只能引用同 namespace |

## 六、调试命令

```bash
# 看 Ingress 的 events（路由合并是否正确）
kubectl describe ingress <name>

# Nginx Ingress：看生成的 nginx.conf
kubectl exec -n ingress-nginx deploy/ingress-nginx-controller -- \
  cat /etc/nginx/nginx.conf | grep -A10 "server_name example.com"

# 看 Ingress 合并后的实际路由表
kubectl get ingress -A
```
