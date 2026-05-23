# Kube API Proxy

K8s API Server 反向代理（Nginx）。

## 文件说明

| 文件 | 说明 |
|---|---|
| [nginx.conf](nginx.conf) | Nginx 反向代理配置：worker_processes 1、events、代理后端 API Server |
| [hosts](hosts) | hosts 解析配置 |
| [docker-compose.yml](docker-compose.yml) | Nginx 代理 Docker Compose 编排 |
