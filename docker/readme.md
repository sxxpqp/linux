# Docker 生态

Docker 安装、镜像构建、docker-compose 服务编排、容器化工具部署。

## 文件/目录说明

| 目录/文件 | 说明 | 状态 |
|---|---|---|
| [docker-install.md](docker-install.md) | Docker 一键安装：清华镜像源加速、指定版本安装（--version 20.10）、用户加入 docker 组、配置加速源 | ✅ 生产验证 |
| [docker-compose/](docker-compose/) | Docker Compose 服务编排合集：Traefik/Portainer/Redis/MySQL/Kafka/GitLab 等中间件编排 | ✅ 生产验证 |
| [containerlab/](containerlab/) | Containerlab 网络仿真工具：快速搭建网络拓扑结构、支持多种网络操作系统 | 验证过 |
| [clash/](clash/) | Clash 代理 Docker 部署：docker run 启动（--net=host 模式）、配置 http_proxy 环境变量 | ✅ 生产验证 |
| [kind/](kind/) | Kind K8s 测试集群：本地快速部署 K8s、ingress-nginx 安装 | 学习笔记 |
| [image/](image.sh) | Docker 镜像管理脚本：批量导出/导入、TAG 处理 | 验证过 |
