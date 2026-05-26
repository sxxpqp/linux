# Loki 日志系统安装步骤

基于 Grafana Loki SimpleScalable 模式，支持 MinIO 本地存储和外部 S3 存储两种方案。

## 部署架构

```text
┌──────────────────────────────────────────────────────────────┐
│                      Loki 日志架构                            │
├──────────────────────────────────────────────────────────────┤
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                      │
│  │ Promtail│  │Promtail │  │Promtail │   ... 日志采集 Agent    │
│  │ (Node 1)│  │(Node 2) │  │(Node N) │                      │
│  └────┬────┘  └────┬────┘  └────┬────┘                      │
│       │             │             │                            │
│       └─────────────┼─────────────┘                            │
│                     │ gRPC/HTTP (loki:3100)                   │
│              ┌──────┴──────┐                                   │
│              │   Gateway   │  LoadBalancer                     │
│              └──────┬──────┘                                   │
│         ┌───────────┼───────────┐                              │
│    ┌────┴────┐ ┌────┴────┐ ┌────┴────┐                        │
│    │  Write  │ │  Write  │ │  Write  │  replicas: 3            │
│    │ (分发日志)│ │ (分发日志)│ │ (分发日志)│                        │
│    └────┬────┘ └────┬────┘ └────┬────┘                        │
│         │           │           │                               │
│    ┌────┴───────────┴───────────┴────┐                         │
│    │           存储后端               │                         │
│    │  ┌──────────┐  ┌─────────────┐  │                         │
│    │  │  MinIO   │  │  外部 S3     │  │                         │
│    │  │ (开发/测试)│  │ (生产推荐)   │  │                         │
│    │  └──────────┘  └─────────────┘  │                         │
│    └─────────────────────────────────┘                         │
│    ┌────┴────┐ ┌────┴────┐                                     │
│    │  Read   │ │  Read   │  replicas: 2 （查询）                │
│    └─────────┘ └─────────┘                                     │
│    ┌────┴────┐ ┌────┴────┐                                     │
│    │ Backend │ │ Backend │  replicas: 2 （Compactor/Index）    │
│    └─────────┘ └─────────┘                                     │
└──────────────────────────────────────────────────────────────┘
```

## 前置条件

- Kubernetes 集群（v1.19+）
- Helm 3 已安装
- kubectl 已配置集群访问权限
- 已安装 **local-path-provisioner** StorageClass（[rancher.io/local-path](https://github.com/rancher/local-path-provisioner)），若未安装参考 [local-path-storage.md](../storageclass/local-path-storage.md)

---

## 1. 添加 Grafana Helm 仓库

```bash
helm repo add grafana https://nexus.ihome.sxxpqp.top:8443/repository/grafana/
helm repo update
```

---

## 2. 安装 Loki

根据存储后端选择对应的 values 文件。

### 方案一：MinIO 本地存储（开发/测试环境）

使用 [values.yaml](values.yaml)，MinIO 随 Loki 一起部署：

```bash
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values values.yaml
```

### 方案二：外部 S3 存储（生产推荐）

使用 [valus-s3.yaml](valus-s3.yaml)，配置外部 S3 端点：

```bash
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values valus-s3.yaml
```

> 部署前修改 `valus-s3.yaml` 中的 S3 连接信息（endpoint、accessKeyId、secretAccessKey、bucketNames）。

---

## 3. 关键配置说明

### 部署模式

| 参数 | 值 | 说明 |
|---|---|---|
| `deploymentMode` | `SimpleScalable` | 简单可扩展模式，读写分离 |
| `auth_enabled` | `false` | 关闭认证（生产环境建议开启） |

### 组件副本数

| 组件 | 副本数 | 说明 |
|---|---|---|
| `write` | `3` | 写入节点，保证数据持久化和复制 |
| `read` | `2` | 读取/查询节点 |
| `backend` | `2` | 后台节点（Compactor、索引管理） |

### PVC 持久化存储

各组件使用 `local-path` StorageClass 自动创建 PVC，数据保存在节点本地磁盘：

| 组件 | 默认大小 | 用途 |
|---|---|---|
| `write` | `50Gi` | WAL 预写日志，对磁盘 I/O 要求高 |
| `read` | `20Gi` | 查询缓存 |
| `backend` | `50Gi` | Compacted 索引存储 |
| `minio` | `100Gi` | 仅方案一，存储日志 chunk 数据 |

对应 values 配置段：

```yaml
write:
  replicas: 3
  persistence:
    storageClass: local-path
    size: 50Gi
read:
  replicas: 2
  persistence:
    storageClass: local-path
    size: 20Gi
backend:
  replicas: 2
  persistence:
    storageClass: local-path
    size: 50Gi
minio:
  persistence:
    storageClass: local-path
    size: 100Gi
```

> [local-path-provisioner](https://github.com/rancher/local-path-provisioner) 会按 `WaitForFirstConsumer` 策略在 Pod 调度的节点上自动创建 `hostPath` 目录，无需手动管理裸盘路径。

### 存储配置

| 参数 | 说明 |
|---|---|
| `schemaConfig.configs[0].store` | `tsdb` — 使用 TSDB 索引存储 |
| `schemaConfig.configs[0].object_store` | `s3` — 对象存储后端 |
| `schemaConfig.configs[0].schema` | `v13` — 索引 schema 版本 |
| `ingester.chunk_encoding` | `snappy` — 日志块压缩算法 |
| `chunk_store_config.max_look_back_period` | `8760h`（365 天）— 最大查询回溯范围 |

### 数据保留配置

```yaml
limits_config:
  retention_period: 8760h          # 日志保留 365 天

# 哈希环副本因子
common:
  replication_factor: 3            # 生产 3 副本，单节点改为 1

compactor:
  retention_enabled: true           # 必须开启，否则 retention 不生效
  compaction_interval: 10m          # 压缩清理间隔
  retention_delete_delay: 2h        # 删除确认延迟，防止误删
  retention_delete_worker_count: 150
```

> `compactor.retention_enabled: true` 是日志自动过期的必要条件，配合 `retention_period` 使用。

### Gateway

| 参数 | 说明 |
|---|---|
| `gateway.service.type` | `LoadBalancer` — 对外暴露 Loki Gateway 入口 |

### MinIO（仅方案一）

| 参数 | 说明 |
|---|---|
| `minio.enabled` | `true` — 自动部署 MinIO 实例 |

### S3 配置（仅方案二）

需在 `loki.storage.s3` 下配置：

| 参数 | 说明 |
|---|---|
| `endpoint` | S3 服务端点（如 `58.49.56.57:8060`） |
| `accessKeyId` / `secretAccessKey` | S3 认证凭证 |
| `insecure` | `true`（HTTP 访问） |
| `s3ForcePathStyle` | `true`（路径风格访问） |
| `bucketNames.chunks` / `index` / `ruler` | 分别指定 chunk、索引、ruler 的 bucket |

---

## 4. 安装 Promtail（日志采集 Agent）

Promtail 部署在集群每个节点收集容器日志并推送到 Loki：

```bash
helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --set config.clients[0].url=http://loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push \
  --set config.clients[0].tenant_id=""
```

| 参数 | 说明 |
|---|---|
| `config.clients[0].url` | Loki Gateway 地址，集群内用完整 DNS |
| `config.clients[0].tenant_id=""` | 关闭 Promtail 的租户 ID 发送（配合 `auth_enabled: false`） |

> Promtail 会以 DaemonSet 方式在每个节点运行，自动采集 `/var/log/pods` 下的容器日志。

### 验证日志是否成功写入

```bash
# 端口转发 Loki Gateway
kubectl -n monitoring port-forward svc/loki-gateway 3100:80
```

```bash
# 查看所有标签（有标签说明日志已在写入）
curl -s http://localhost:3100/loki/api/v1/labels | jq '.data'

# 查询日志
curl -s -G http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={namespace="monitoring"}' \
  --data-urlencode 'limit=5' | jq '.data.result'
```

如果返回 `labels` 为空，检查 Promtail 日志：

```bash
kubectl -n monitoring logs -l app.kubernetes.io/name=promtail --tail=50
```

常见原因：
- `config.clients[0].url` 地址不对 — 确认 Loki Gateway Service 名称和端口
- Loki Gateway 未 Ready — `kubectl -n monitoring get pods -l app.kubernetes.io/name=loki`
- Promtail DaemonSet 未调度到所有节点 — `kubectl -n monitoring get ds promtail`

---

## 5. 在 Grafana 中添加 Loki 数据源

1. 登录 Grafana（`http://localhost:3000`）
2. 进入 **Configuration → Data Sources → Add data source**
3. 选择 **Loki**
4. URL 填入：`http://loki-gateway.monitoring.svc:80`
5. 点击 **Save & Test**

现在可以在 Grafana Explore 中通过 LogQL 查询日志。

---

## 6. 验证

```bash
# 查看 Loki 组件
kubectl -n monitoring get pods -l app.kubernetes.io/name=loki

# 查看 Promtail
kubectl -n monitoring get pods -l app.kubernetes.io/name=promtail

# 查看 Loki Service
kubectl -n monitoring get svc -l app.kubernetes.io/name=loki

# 端口转发 Gateway 测试
kubectl -n monitoring port-forward svc/loki-gateway 3100:80

# 测试 Loki API
curl http://localhost:3100/loki/api/v1/status/buildinfo

# 查询标签
curl http://localhost:3100/loki/api/v1/labels
```

---

## 7. 常用 LogQL 查询示例

```logql
# 查询所有日志
{job=~".+"}

# 按 namespace 过滤
{namespace="monitoring"}

# 按 Pod 名称过滤
{pod=~"loki-write.*"}

# 关键字搜索
{namespace="default"} |= "ERROR"

# 排除关键字
{namespace="default"} != "DEBUG"

# 正则匹配
{app="nginx"} |~ "status=[4-5][0-9]{2}"

# 按时间范围 + 计数
count_over_time({namespace="production"} |= "ERROR" [5m])
```

---

## 8. 文件索引

| 文件 | 用途 |
|---|---|
| [values.yaml](values.yaml) | MinIO 存储方案配置（SimpleScalable，3x write / 2x read / 2x backend） |
| [valus-s3.yaml](valus-s3.yaml) | 外部 S3 存储方案配置（生产环境推荐） |

---

## 9. 常见问题

### 9.1 StatefulSet 升级失败：spec is invalid

添加 `persistence` 到已有 Loki 时，StatefulSet 的 `volumeClaimTemplates` 不可修改，报错：

```
StatefulSet.apps "loki-backend" is invalid: spec: Forbidden: updates to statefulset spec ...
```

解决：卸载后重新安装（日志数据在对象存储中，不会丢失）。

```bash
helm uninstall loki -n monitoring
kubectl -n monitoring wait --for=delete pod -l app.kubernetes.io/name=loki --timeout=120s

# 清理旧 PVC（如果带 storageClass 的 PVC 也异常）
kubectl -n monitoring delete pvc -l app.kubernetes.io/name=loki

# 重新安装
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values valus-s3.yaml
```

### 9.2 PVC 长时间 Pending

```bash
kubectl -n monitoring get pvc
kubectl -n monitoring describe pvc <pvc-name>
```

常见原因：

| 原因 | 解决 |
|---|---|
| 没有默认 StorageClass | `kubectl get sc` 确认 `local-path` 存在且标记为 default，或 values 中显式指定 `storageClass: local-path` |
| `WaitForFirstConsumer` 模式下 Pod 未调度 | PVC 等 Pod 创建后才触发绑定，确认对应 Pod Running：`kubectl -n monitoring get pods -l app.kubernetes.io/name=loki` |
| 节点磁盘不足 | `kubectl describe pvc` 查看 Events，扩容或清理节点磁盘 |

### 9.3 Promtail 运行但 Loki 查不到日志

```bash
# 检查 Promtail 日志
kubectl -n monitoring logs -l app.kubernetes.io/name=promtail --tail=20

# 确认 client URL 正确（末尾路径不能少）
kubectl -n monitoring get svc loki-gateway

# 确认 Loki write 节点 Ready
kubectl -n monitoring get pods -l app.kubernetes.io/name=loki,app.kubernetes.io/component=write
```

### 9.4 Loki 日志保留不生效

确认 `compactor.retention_enabled: true` 且 `limits_config.retention_period` 已设置。查看 Compactor 是否正常工作：

```bash
kubectl -n monitoring logs -l app.kubernetes.io/component=backend --tail=30 | grep -i retention
```
