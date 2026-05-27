# Tempo 分布式 Trace 安装步骤（生产环境）

基于 Grafana Tempo Helm Chart，3 副本 + MinIO S3 共享存储，高可用部署。

## 部署架构

```text
  MinIO S3 (tempo-traces bucket)
         ▲
  ┌──────┼──────┐
  │      │      │
Tempo-0 Tempo-1 Tempo-2   ← 3 副本，共享 S3
  │      │      │
  └──────┼──────┘
         │ tempo.observability:4317 (Service DNS 负载均衡)
         ▲
    ┌────┴────┐
    │  Alloy  │  ← DaemonSet，每节点一个
    │ :4317   │
    └────▲────┘
         │ OTLP
    ┌────┴────┐
    │  Beyla  │  ← eBPF 零侵入
    │ / SDK   │
    └─────────┘
```

## 前置条件

- Kubernetes 集群
- Helm 3
- MinIO 已部署（`minio.observability:9000`，bucket `tempo-traces` 已创建）
- Alloy 已部署
- Beyla 已部署（可选）

> 如果还没有 MinIO，先部署：[minio.yaml](../../observability/minio.yaml)

---

## 1. 添加 Grafana Helm 仓库

```bash
helm repo add grafana https://nexus.ihome.sxxpqp.top:8443/repository/grafana/
helm repo update
```

---

## 2. 安装 Tempo

```bash
helm install tempo grafana/tempo \
  --namespace observability \
  --values values.yaml \
  --wait --timeout 5m
```

---

## 3. 关键配置

| 参数 | 值 | 说明 |
|---|---|---|
| `tempo.replicas` | `3` | 高可用，任意一个 Pod 挂了不影响写入 |
| `tempo.storage.trace.backend` | `s3` | MinIO S3 共享存储 |
| `tempo.storage.trace.s3.bucket` | `tempo-traces` | Bucket 需在 MinIO 中预先创建 |
| `tempo.storage.trace.s3.endpoint` | `minio.observability:9000` | MinIO Service DNS |
| `service.ports[2]` | `3200` | HTTP 查询端口，Grafana 连这个 |

### 端口说明

| 端口 | 协议 | 用途 | 谁连 |
|------|------|------|------|
| `4317` | OTLP gRPC | 接收 Trace 数据 | Alloy → Distributor |
| `4318` | OTLP HTTP | 接收 Trace 数据 | 备用 |
| `3200` | HTTP | 查询 Trace | Grafana → Tempo |

---

## 4. 在 Grafana 中添加 Tempo 数据源

```yaml
# grafana-values.yaml
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Tempo
        type: tempo
        url: http://tempo-query-frontend.observability:3200
        access: proxy
        isDefault: true
        jsonData:
          nodeGraph:
            enabled: true
```

---

## 5. 验证

```bash
# 确认 3 个 Pod Running
kubectl -n observability get pods -l app.kubernetes.io/name=tempo

# 确认 Service
kubectl -n observability get svc tempo

# 端口转发查询端口
kubectl -n observability port-forward svc/tempo-query-frontend 3200:3200 &

# 健康检查
curl http://localhost:3200/ready

# 搜索 Trace
curl http://localhost:3200/api/search

# 确认 MinIO 中有数据写入
kubectl logs -n observability tempo-0 | grep -i "written\|flushed"
```

---

## 6. 常见问题

### Tempo 连不上 MinIO

```bash
# 确认 MinIO Service DNS 可解析
kubectl run -it --rm debug --image=busybox -n observability -- nslookup minio.observability

# 确认 bucket 存在
kubectl port-forward svc/minio -n observability 9001:9001
# 浏览器打开 http://localhost:9001 → 登录 minioadmin/minioadmin → 看 Buckets

# 手动创建 bucket
kubectl exec -n observability deploy/minio -- mc alias set local http://localhost:9000 minioadmin minioadmin
kubectl exec -n observability deploy/minio -- mc mb local/tempo-traces --ignore-existing
```

### Alloy 发送 Trace 失败

```bash
# 确认 Distributor 4317 端口在监听
kubectl exec -n observability deploy/tempo-distributor -- ss -tlnp | grep 4317

# Alloy 日志确认
kubectl logs -n observability -l app=alloy --tail=20 | grep -i "tempo\|error"
```

---

## 7. 文件索引

| 文件 | 用途 |
|---|---|
| [values.yaml](values.yaml) | Tempo Helm values（3 副本 + MinIO S3） |
