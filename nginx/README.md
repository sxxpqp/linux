# Nginx 配置

Nginx 反向代理、SSL/TLS 安全配置、HTTP-FLV 直播流、K8s ConfigMap 部署。

## 文件说明

| 文件 | 说明 | 状态 |
|---|---|---|
| [nginx.cnf](nginx.cnf) | Nginx 主配置：upstream 后端服务器组、SSL 证书配置、location 转发规则、反向代理 header 透传 | ✅ 生产验证 |
| [nginx-ssl.cnf](nginx-ssl.cnf) | SSL 配置：TLSv1.2+TLSv1.3 协议控制、加密套件、OCSP Stapling、HSTS | ✅ 生产验证 |
| [nginxproxy.md](nginxproxy.md) | Nginx 反向代理转发规则详解：proxy_pass 带/不带 / 的 URI 截断行为、ingress-nginx rewrite-target 使用方式 | 验证过 |
| [dist.cnf](dist.cnf) | 静态资源分发配置 | 验证过 |
| [httpflv.conf](httpflv.conf) | HTTP-FLV 直播流配置：HTTP 重定向 HTTPS、反向代理后端直播服务 8082 端口、CORS 跨域配置 | ✅ 生产验证 |
| [nginx-cm.yaml](nginx-cm.yaml) | Nginx ConfigMap（K8s 部署用） | ✅ 生产验证 |
| [Dockerfile](Dockerfile) | Nginx Docker 镜像构建：基于官方 nginx 镜像，复制 dist 静态资源和 default.conf |
