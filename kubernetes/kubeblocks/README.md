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
├── install.sh               装 KubeBlocks operator (v1.0.2, bundled addon 自动启用)
├── uninstall.sh             卸载 operator
├── install-snapshotter.sh   装 VolumeSnapshot CRD + controller (备份依赖)
└── redis-cluster/
    ├── cluster.yaml         Cluster CR (Redis 7.2.4, sharding 3×2, NodePort 启用)
    ├── install.sh           apply CR + 同步密码到固定 Secret + 显示连接信息
    ├── scale.sh             扩缩 shards (OpsRequest, operator 自动 reshard 槽位)
    └── uninstall.sh         删 Cluster (--keep-data / --purge / --force)
```

## 完整操作矩阵

| 操作 | 命令 |
|---|---|
| **装 operator** | `bash install.sh` |
| **装 snapshot CRD** | `bash install-snapshotter.sh` |
| **建 Redis Cluster** | `cd redis-cluster && bash install.sh --wait` |
| **扩容 3→4 shard (6→8 pod)** | `cd redis-cluster && bash scale.sh 4 --wait` |
| **缩容 4→3 shard** | `cd redis-cluster && bash scale.sh 3 --wait` |
| **取密码** | `kubectl get secret redis-cluster-password -n test -o jsonpath='{.data.password}' \| base64 -d; echo` |
| **看 NodePort 表** | `kubectl get svc -n test \| grep advertised` |
| **删 Redis Cluster** | `cd redis-cluster && bash uninstall.sh` |
| **保留数据删 Cluster** | `cd redis-cluster && bash uninstall.sh --keep-data` |
| **卡死强清** | `cd redis-cluster && bash uninstall.sh --force` |
| **卸 operator** | `bash uninstall.sh` |
| **完全清理 operator+CRD** | `bash uninstall.sh --purge` |

## 一键脚本

```bash
# 1. 装 KubeBlocks operator + snapshot-controller (备份依赖)
cd kubernetes/kubeblocks
bash install.sh                       # operator + bundled addons
bash install-snapshotter.sh           # VolumeSnapshot CRD + controller (一次性)

# 2. 部署 Redis Sharding Cluster (Redis 7.2.4, 3 shard × 2 副本 = 6 pod)
cd redis-cluster
bash install.sh --wait                # apply + 等 Running + 显示所有连接信息

# 3. 扩缩容 (按 shards 数, 1 shard = 2 pod)
bash scale.sh 4 --wait                # 3 → 4 shard (6 → 8 pod)
bash scale.sh 3 --wait                # 缩回
```

### 密码 (自动生成, 同步到固定 Secret)

KubeBlocks 自动给每个 shard 生成密码 (值相同), `install.sh` 跑完会同步到统一名字 `redis-cluster-password`:

```bash
# 业务侧统一用这条
kubectl get secret redis-cluster-password -n test -o jsonpath='{.data.password}' | base64 -d; echo
```

### 外部访问 (NodePort)

`cluster.yaml` 里启用了 `services[].podService: true`, 每个 pod 自动分配独立 NodePort. Redis Cluster 客户端用任一 NodePort 连接, 自动跟随 MOVED 重定向:

```bash
# install.sh 末尾会列出所有 NodePort 表, 也可以随时查:
kubectl get svc -n test -l app.kubernetes.io/instance=redis-cluster | grep advertised

# 外部连接 (任一 node IP + 任一 NodePort 都行)
PASS=$(kubectl get secret redis-cluster-password -n test -o jsonpath='{.data.password}' | base64 -d)
redis-cli -h <node-ip> -p <nodeport> -a "$PASS" -c cluster info
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
