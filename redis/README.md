# Redis 运维

Redis **通用运维知识 + 容量规划**。具体部署模板在子目录:

> Docker Compose 部署见 [../docker/docker-compose/redis/](../docker/docker-compose/redis/)
> K8s 部署见 [../kubernetes/redis/](../kubernetes/redis/)

## 文件说明

| 文件 | 说明 | 状态 |
|---|---|---|
| [capacity-planning.md](capacity-planning.md) | **Redis 容量规划 / 性能瓶颈速查**:完整请求链路 + 4 资源轴 trade-off + 4 种部署模式对比 + 8C16G 推荐配置 + 排障命令速查 + 容器化坑 + 24G fork 60s 真实案例 | ✅ 生产参考 |
| [fix-prod-fork.sh](fix-prod-fork.sh) | **一键修复脚本**:fork 慢 + 误切换三层加固(OS / Redis / Cluster),幂等,支持 `--dry-run`,集群模式自动遍历所有节点 | ✅ 生产参考 |

## 快速决策

| 问题 | 走这里 |
|---|---|
| QPS 上不去 / 单线程跑满 | [capacity-planning.md#资源关系公式](capacity-planning.md) → Cluster 分片 |
| 内存涨太快 / OOM | [capacity-planning.md#可复用排障清单](capacity-planning.md) → `--bigkeys` / `INFO memory` |
| Fork 卡住业务 | [capacity-planning.md#容器化k8s额外坑](capacity-planning.md) → `vm.overcommit_memory=1` + 关 THP |
| 哨兵还是集群? | [capacity-planning.md#4-种典型部署模式-trade-off](capacity-planning.md) → < 32G 用 Sentinel,> 64G 用 Cluster |
| 持久化方案 | [capacity-planning.md#关键-trade-off](capacity-planning.md) → 缓存全关,数据 RDB+AOF |
