# Ingress 常用 Annotation

> 生产实战经验总结，2026-06-16 记录

## 使用频率分级

```
常用级（基本每次写 Ingress 都要配）：
├── proxy-body-size
├── enable-cors
├── rewrite-target
├── limit-rps
├── whitelist-source-range
├── canary

场景级（用到了就配）：
├── affinity
├── upstream-hash-by
├── server-snippet
```

## 一、proxy-body-size（请求体限制）

**作用：** 限制请求体大小，默认 Nginx 只允许 1m，不配上传文件就 413

```yaml
nginx.ingress.kubernetes.io/proxy-body-size: "50m"
```

**场景：** 文件上传、大表单提交

## 二、enable-cors（跨域）

**作用：** 前后端分离时，前端跨域请求后端

```yaml
nginx.ingress.kubernetes.io/enable-cors: "true"
nginx.ingress.kubernetes.io/cors-allow-origin: "https://admin.example.com"
nginx.ingress.kubernetes.io/cors-allow-methods: "GET, POST, PUT, DELETE"
nginx.ingress.kubernetes.io/cors-allow-headers: "Authorization, Content-Type"
```

**场景：** 前后端分离项目

## 三、rewrite-target（路径重写）

**作用：** 前端路径和后端路径不一致时做映射

```yaml
nginx.ingress.kubernetes.io/rewrite-target: /$2
```

**场景：**
```
前端访问 /api/users → 后端服务是 /users
前端访问 /api/orders → 后端服务是 /orders
```

**注意：** rewrite-target 作用于整个 Ingress，如果不需要重写的路由也在同一个 Ingress 里，必须拆开。

## 四、limit-rps（限流）

**作用：** 限制每秒请求数，防刷防突发

```yaml
nginx.ingress.kubernetes.io/limit-rps: "100"       # 每秒请求数
nginx.ingress.kubernetes.io/limit-burst: "200"      # 突发上限
```

**场景：** 暴露到公网的服务

## 五、whitelist-source-range（IP 白名单）

**作用：** 只允许指定 IP 段访问

```yaml
nginx.ingress.kubernetes.io/whitelist-source-range: "10.0.0.0/8,172.16.0.0/16"
```

**场景：** 管理后台、Prometheus、Grafana 等内网服务

## 六、canary（灰度发布）

**作用：** 新版本上线时，先放部分流量验证

```yaml
nginx.ingress.kubernetes.io/canary: "true"
nginx.ingress.kubernetes.io/canary-weight: "10"   # 10% 流量
# 或按 Header 灰度
# nginx.ingress.kubernetes.io/canary-by-header: "X-Canary"
# nginx.ingress.kubernetes.io/canary-by-header-value: "true"
```

**场景：** 任何上线操作，不管项目大小

## 七、affinity（会话保持）

**作用：** 同一个用户的请求始终打到同一个 Pod

```yaml
nginx.ingress.kubernetes.io/affinity: "cookie"
```

**场景：** WebSocket、长连接

## 八、upstream-hash-by（IP Hash）

**作用：** 同一个 IP 始终打到同一个 Pod

```yaml
nginx.ingress.kubernetes.io/upstream-hash-by: "$remote_addr"
```

**场景：** 本地缓存优化场景

## 九、server-snippet（注入自定义配置）

**作用：** Ingress Annotation 表达能力不够时，直接手写 nginx 配置

```yaml
nginx.ingress.kubernetes.io/server-snippet: |
  if ($host ~* ^admin\.) {
    return 403;
  }
```

**场景：** 特殊安全策略、自定义逻辑
