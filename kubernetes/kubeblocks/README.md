# KubeBlocks 数据库 Operator

[KubeBlocks](https://kubeblocks.io/) 是 ApeCloud 出品的 K8s 数据库 operator，统一管理 Redis / MySQL / PostgreSQL / MongoDB / Kafka / Pulsar / Elasticsearch 等 30+ 种数据引擎。

## 为什么用它替代 Bitnami chart

| 痛点 | Bitnami | KubeBlocks |
|---|---|---|
| Pod 重启后 IP 变 → Redis Cluster 路由表失效 | ❌ StatefulSet 用裸 hostname，需手动 `CLUSTER MEET` 修复 | ✅ InstanceSet + reload hook 自动更新 `cluster-announce-ip` |
| 备份恢复 | ❌ 自己写脚本 | ✅ 内置 BackupPolicy / Restore CR |
| 主从切换 | ❌ Sentinel 模式才有 | ✅ 内置 switchover 命令 |
| 扩缩容 | ⚠️ 改 replicas 后 cluster topology 不会自动 reshard | ✅ HorizontalScaling / VerticalScaling OpsRequest 自动 reshard |
| 跨数据库统一 API | ❌ 每种 DB 一个 chart 一套字段 | ✅ Cluster CR 统一抽象 |

最关键的是**第一条** —— Bitnami Redis Cluster 用 Pod IP 标识节点，Pod 一重启 IP 就变（哪怕用 PVC 数据是对的），老的 `nodes.conf` 找不到新 IP 就回到 `cluster_state:fail`。KubeBlocks 给每个副本一个稳定的 Service + InstanceSet，配合 reload 钩子规避这一类问题。

## 项目结构

```
kubeblocks/
├── README.md
├── install.sh         一键装 operator (kb-system 命名空间)
├── uninstall.sh       卸载 operator
└── redis-cluster/
    ├── cluster.yaml   Cluster CR (3主3从, longhorn 存储)
    └── deploy.sh      一键应用 CR
```

## 一键脚本

```bash
# 1. 装 KubeBlocks operator
cd kubernetes/kubeblocks
bash install.sh                       # 默认 v0.9.3 + 启用 Redis/MySQL/PG/Mongo/Kafka addon

# 2. 部署 Redis Cluster 实例
cd redis-cluster
bash deploy.sh --wait                 # 部署后等 Running

# 3. 验证 cluster_state
PASS=$(kubectl get secret redis-cluster-conn-credential -n test -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n test -it redis-cluster-redis-cluster-0 -- redis-cli -a "$PASS" cluster info | grep cluster_state
# 期望: cluster_state:ok
```

## 卸载

```bash
# 只删 operator, 保留所有 Cluster 实例和数据 (生产推荐先这么做, 确认无业务再 purge)
bash uninstall.sh

# 同时删除所有 Cluster 实例 + PVC + CRD (数据丢失, 不可逆)
bash uninstall.sh --purge
```

## Cluster 的删除策略

`spec.terminationPolicy` 控制 `kubectl delete cluster` 时的行为：

| 策略 | 行为 | 适用场景 |
|---|---|---|
| `DoNotTerminate` | 拒绝删除 | 生产环境，需要先改成其他策略才能删 |
| `Halt` | 删 Pod/SVC 但保留 PVC | 临时停服省钱 |
| `Delete` | 删 Pod/SVC + PVC | **当前默认**，开发/测试 |
| `WipeOut` | Delete + 删除远程备份 | 彻底清退 |

## OpsRequest 操作

KubeBlocks 把所有"运维操作"封装成 `OpsRequest` CR：

```yaml
# 例：横向扩容到 9 节点
apiVersion: apps.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: redis-cluster-scale-out
spec:
  clusterRef: redis-cluster
  type: HorizontalScaling
  horizontalScaling:
    - componentName: redis-cluster
      replicas: 9
```

Operator 会自动：
1. 起新 Pod
2. `CLUSTER MEET` 加入集群
3. 触发 `CLUSTER RESHARD` 迁移槽位
4. 等待数据完成迁移
5. 更新 cluster status

不需要手动跑 `redis-cli --cluster reshard` 那一长串。

其他 OpsRequest 类型：
- `VerticalScaling` — 改 CPU/内存
- `VolumeExpansion` — PVC 扩容
- `Restart` — 滚动重启
- `Switchover` — 主从切换
- `Upgrade` — 升级 Redis 版本
- `Reconfiguring` — 改 Redis 配置（自动判断要不要重启）

## 现有 Bitnami → KubeBlocks 迁移建议

如果 `test` namespace 还有 Bitnami 的 `redis-cluster-*` StatefulSet，**两边不能并存**（Service 名冲突）。迁移步骤：

```bash
# 1. 备份 Bitnami 集群数据（如有）
kubectl exec -n test redis-cluster-0 -c redis-cluster -- \
  sh -c 'redis-cli -a "$REDIS_PASSWORD" --rdb /tmp/dump.rdb'
kubectl cp test/redis-cluster-0:/tmp/dump.rdb ./dump.rdb -c redis-cluster

# 2. 卸载 Bitnami chart
helm uninstall redis-cluster -n test
kubectl delete pvc -l app.kubernetes.io/name=redis-cluster -n test   # 看自己要不要删

# 3. 装 KubeBlocks (operator + Cluster CR)
cd kubernetes/kubeblocks
bash install.sh
cd redis-cluster && bash deploy.sh --wait

# 4. 数据导入 (可选, 如果有 dump.rdb 要恢复)
kubectl cp ./dump.rdb test/redis-cluster-redis-cluster-0:/data/dump.rdb -c redis-cluster
kubectl rollout restart instanceset redis-cluster-redis-cluster -n test
```

## 关联组件

- 监控：跟现有 [../observability/](../observability/) 的 Prometheus / Grafana 直接打通
- 备份存储：可接 [../observability/minio.yaml](../observability/minio.yaml) 的 MinIO 当 S3 后端

## 参考

- 官方文档：<https://kubeblocks.io/docs/release-0_9/preview/>
- 已知问题（Redis IP 切换）：<https://github.com/apecloud/kubeblocks/issues>
- Helm chart 索引：<https://apecloud.github.io/helm-charts>
