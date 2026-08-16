# KubeBlocks MinIO 分布式集群

基于 KubeBlocks 官方 minio addon 管理 MinIO 分布式集群，与 Redis/MySQL/Kafka 统一用 Cluster CR + OpsRequest 管理。

> Bitnami Helm 版已移至 `../minio-bitnami/`，不再维护。

## 快速开始

```bash
# 部署 (默认 ns=test, 4 副本)
bash install.sh --wait

# 指定 namespace 和副本数
bash install.sh --ns prod --replicas 8 --wait
```

## 文件说明

| 文件 | 用途 |
|---|---|
| `cluster.yaml` | Cluster CR 模板 (4 副本, 100Gi/节点) |
| `install.sh` | 一键部署 (自动启用 addon + 部署 + 拉凭证) |
| `scale.sh` | 扩缩容 (OpsRequest, 必须偶数 ≥4) |
| `uninstall.sh` | 卸载 (支持 --keep-data / --purge / --force) |

## 连接信息

```bash
# 集群内 S3 API
http://minio-cluster-minio.<ns>.svc:9000

# Console UI (port-forward)
kubectl port-forward -n <ns> svc/minio-cluster-frontend 9001:9001
# 浏览器打开 http://localhost:9001

# 凭证
kubectl get secret -n <ns> minio-cluster-minio-account-root \
  -o jsonpath='{.data.username}' | base64 -d; echo
kubectl get secret -n <ns> minio-cluster-minio-account-root \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## 扩缩容

```bash
bash scale.sh 6          # 扩到 6 副本
bash scale.sh --wait 8   # 扩到 8 副本并等待完成
```

⚠ **扩容后注意**：新副本可能报 `grid re-connecting` 错误（MinIO 纠删码已知行为），需要：
- 方案 1：执行一次 STOP → START OpsRequest（推荐）
- 方案 2：删除旧 pod 触发重连 `kubectl delete pod minio-cluster-minio-{0..N}`

## 与 Bitnami 版对比

| 维度 | KubeBlocks (本目录) | Bitnami Helm (../minio-bitnami/) |
|---|---|---|
| 管理方式 | Cluster CR + OpsRequest | helm upgrade |
| 扩缩容 | ✅ OpsRequest 原生支持 | ❌ 不能改 replicas |
| 备份 | ✅ BackupSchedule | 手动 mc mirror |
| 监控 | ✅ addon 自带 dashboard | 自己接 |
| 统一管控 | ✅ 跟 Redis/MySQL/Kafka 同 API | 独立体系 |
