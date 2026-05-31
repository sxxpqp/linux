# clash (已弃用归档)

> **🟡 已停用** — clash 客户端方案已全面迁到 **mihomo**(裸核 + TUN),见仓库根 `network/mihomo/`。
> 本目录保留作"自构建 clash docker 镜像"的历史参考,**不要在新项目里继续用**。

## 历史用法(失效警告)

下面命令引用的 `dockerproxy.com` 镜像加速器**已基本不可用**:

```bash
docker run --privileged -d --net=host --name=clash dockerproxy.com/sxxpqp/clash:v1
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
curl -I https://google.com
```

如果一定要再跑这个镜像,改成走自家阿里云:

```bash
docker run --privileged -d --net=host --name=clash \
  registry.cn-hangzhou.aliyuncs.com/sxxpqp/clash:v1
```

## 文件说明

| 文件 | 用途 |
|---|---|
| `Dockerfile` | 自构建 clash 容器 |
| `config.yaml` | clash 配置(节点 / 规则) |
| `docker-compose.yml` | compose 启动 |
| `push_rs.sh` | 推送规则集脚本 |
| `update_image.sh` | 重建并推送镜像 |

## 推荐替代

- **桌面/服务器代理**: [`network/mihomo/`](../../network/mihomo/) — 裸核 TUN,性能好,配置统一
- **docker compose 历史归档**: [`../docker-compose/archived/clash/`](../docker-compose/archived/clash/) — 老 config 副本
