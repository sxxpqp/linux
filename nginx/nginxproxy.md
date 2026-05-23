# 场景1：proxy_pass 不带 URI（nginx-ingress 做法）
location /api/ {
    proxy_pass http://backend;
    # /api/foo  →  /api/foo  （原样）
}
# 不管 location 末尾带不带 /，proxy_pass 没有 URI 就不截取


# 场景2：proxy_pass 带了 /（或任何 URI 路径）
# ✅ 建议 location 也带尾斜杠，截取行为才符合预期
location /api/ {
    proxy_pass http://backend/;
    # /api/foo  →  /foo  （截取 /api/ 部分，拿剩余部分拼到 / 后面）
}

# ❌ location 不带 / 会有问题
location /api {
    proxy_pass http://backend/;
    # /api      →  /         （把 /api 整条截掉，只留空串）
    # /api/foo  →  /foo      （截掉 /api，剩下 /foo）
    # /api123   →  123       （截掉 /api，剩下 123，乱套了）
}

所以规律就是：

proxy_pass 没 URI 路径（http://ip:port 结尾）→ 原样转发，location 带不带 / 无所谓
proxy_pass 有 URI 路径（http://ip:port/ 或 http://ip:port/something）→ nginx 会截掉 location 匹配的部分，这时候 location 和 proxy_pass 末尾 / 要对应好，否则路径会乱拼
ingress-nginx 选第一种（原样转发），规避了这一整套麻烦，路径控制统一交给 rewrite-target


需求：把 /api/v1/users 转发给后端 /users
标准 nginx 方式（截取）

location /api/v1/ {
    proxy_pass http://backend/;
    # /api/v1/users  →  /users
}
ingress-nginx 方式（原样转发 + rewrite-target）

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
请求链路

客户端 GET /api/v1/users

ingress-nginx 匹配到 path: /api/v1(/|$)(.*)
              → 捕获组 $1 = /, $2 = users

rewrite-target: "/$2"
              → URI 从 /api/v1/users 内部改写为 /users

proxy_pass http://demo-svc:8080/users  ← 原样转发改写后的路径

后端收到 GET /users
浏览器地址栏不变（还是 /api/v1/users）
这样就把标准 nginx 那种 proxy_pass + location 截取的隐式行为，变成了 通过 rewrite-target 显式控制路径，意思更清楚，不容易搞错。