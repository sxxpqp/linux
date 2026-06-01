# nps 内网穿透

基于 nps/npc 的内网穿透方案，nps 为服务端，npc 为客户端。

## 文件说明

| 文件/目录 | 说明 |
|---|---|
| [install.sh](install.sh) | Docker 一键安装脚本（支持 server / client / all / uninstall） |
| [.env](.env) | 配置变量（端口、密钥、镜像等） |
| [server/](server/) | nps 服务端配置（conf 文件、Web 管理界面端口设置） |
| [client/](client/) | nps 客户端（npc）配置 |
| [image.png](image.png) | nps 网络拓扑示意图 |
