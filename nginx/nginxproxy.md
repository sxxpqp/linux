# Nginx proxy_pass 路径转发规则

> 标准 nginx 的 `proxy_pass` + `location` 路径截取行为容易踩坑,ingress-nginx 用 `rewrite-target` 规避了一整套麻烦。本文讲清两套写法的区别 + 何时选哪种。

## TL;DR 核心规律

| `proxy_pass` 形态 | 行为 | location 末尾 `/` 要求 |
|---|---|---|
| `proxy_pass http://backend;`(**没 URI**) | **原样转发** | 带不带 `/` 都无所谓 |
| `proxy_pass http://backend/;` 或 `http://backend/xxx;`(**有 URI**) | 截掉 location 匹配部分,**剩余拼到 URI 后** | `location` 和 `proxy_pass` 的 `/` **必须对应**,否则路径错乱 |

**一句话**:`proxy_pass` 带 URI 时,nginx 会做"截取 + 拼接",这套规则隐式且容易出错。ingress-nginx 选择第一种(原样转发)+ `rewrite-target` 显式控制,意思更清楚。

---

## 场景 1:`proxy_pass` 不带 URI(ingress-nginx 做法)

```nginx
location /api/ {
    proxy_pass http://backend;
    # /api/foo  →  /api/foo  (原样)
}
```

不管 `location` 末尾带不带 `/`,`proxy_pass` 没有 URI 就**不截取**,请求路径原样转给后端。

## 场景 2:`proxy_pass` 带了 `/`(或任何 URI 路径)

### ✅ 推荐:`location` 也带尾斜杠

```nginx
location /api/ {
    proxy_pass http://backend/;
    # /api/foo  →  /foo  (截取 /api/,剩余 foo 拼到 / 后面)
}
```

### ❌ 反例:`location` 不带 `/`

```nginx
location /api {
    proxy_pass http://backend/;
    # /api      →  /         (把 /api 整条截掉,只留空串)
    # /api/foo  →  /foo      (截掉 /api,剩下 /foo)
    # /api123   →  123       (截掉 /api,剩下 123 — 乱套了)
}
```

`/api123` 这种"前缀匹配但不是预期边界"的情况会把 `123` 当成有效路径转给后端,经常踩坑。

---

## 实战:把 `/api/v1/users` 转给后端 `/users`

需求:外部访问 `/api/v1/users`,后端实际收到 `/users`(剥掉 `/api/v1` 前缀)。

### 方式 A:标准 nginx(用 location 截取)

```nginx
location /api/v1/ {
    proxy_pass http://backend/;
    # /api/v1/users  →  /users
}
```

简洁但**隐式**:必须记住"`/api/v1/` 末尾 `/` + `http://backend/` 末尾 `/`"的对应关系,改 location 路径时容易把这条规则破坏掉。

### 方式 B:ingress-nginx(原样转发 + rewrite-target)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: "/$2"
    nginx.ingress.kubernetes.io/use-regex: "true"
spec:
  rules:
    - host: www.example.com
      http:
        paths:
          - path: /api/v1(/|$)(.*)
            backend:
              serviceName: demo-svc
              servicePort: 8080
```

### 请求链路

```
客户端 GET /api/v1/users
        │
        ▼
ingress-nginx 匹配 path: /api/v1(/|$)(.*)
        │  捕获组 $1 = "/", $2 = "users"
        ▼
rewrite-target: "/$2"
        │  URI 从 /api/v1/users 内部改写为 /users
        ▼
proxy_pass http://demo-svc:8080/users  ← 原样转发改写后的路径
        │
        ▼
后端收到 GET /users
浏览器地址栏不变(还是 /api/v1/users)
```

把"`proxy_pass` + `location` 隐式截取"显式化为"`rewrite-target` 改写 URI",**意图清楚,不容易搞错**。

---

## 选哪种

| 场景 | 推荐 |
|---|---|
| 裸 nginx,简单转发,路径不需要复杂改写 | 方式 A(标准 nginx 截取),记牢 `location` 和 `proxy_pass` 末尾 `/` 对应 |
| K8s 集群里走 ingress-nginx | 方式 B(rewrite-target),路径控制集中在 annotation,跟 nginx 默认行为解耦 |
| 路径里有正则 / 多段捕获 / 条件改写 | 方式 B 配合 `use-regex: "true"` + `rewrite-target: "/$N"` |
