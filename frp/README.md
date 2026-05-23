# frp 内网穿透

基于 frp 的内网穿透方案，支持 Docker Compose 和 K8s 部署。配置文件使用 TOML 格式（frp v0.52+），不再使用旧版 INI 格式。

## 文件说明

| 目录 | 说明 |
|---|---|
| [docker/](docker/) | frps/frpc Docker Compose 部署：服务端映射端口、客户端配置代理规则，防火墙放行说明 |
| [k8s/](k8s/) | K8s 部署 frpc DaemonSet：ConfigMap 配置 TOML 格式代理规则，支持多隧道代理 |
