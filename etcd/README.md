# etcd 集群

etcd 集群 Docker Compose 部署及 Nginx 反向代理。

## 文件说明

| 文件/目录 | 说明 |
|---|---|
| [docker-compose.yml](docker-compose.yml) | etcd 3 节点集群：基于 bitnami/etcd:3.5 镜像、peer/client 端口配置、集群 token 初始化、数据持久化卷、traefik 网络 |
| [nginx.conf](nginx.conf) | etcd 反向代理 Nginx 配置，代理后端 etcd 节点 2379 端口 |
| [vm/](vm/) | etcd 虚拟机部署相关配置 |
