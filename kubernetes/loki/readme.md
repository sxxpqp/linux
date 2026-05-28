# Loki 日志系统

基于 Grafana Loki SimpleScalable 模式，支持 MinIO 本地存储和外部 S3 存储。

## 一键脚本

| 脚本 | 用途 |
|---|---|
| [install.sh](install.sh) | 一键安装（默认 MinIO，`--s3` 切外部 S3） |
| [uninstall.sh](uninstall.sh) | 一键卸载（保留 PVC，`--purge` 完整清理） |

```bash
bash install.sh             # 用 values.yaml (MinIO)
bash install.sh --s3        # 用 values-s3.yaml (外部 S3)

bash uninstall.sh           # 保留历史日志
bash uninstall.sh --purge   # 同时删 PVC
```

## 文件索引

| 文件 | 说明 |
|---|---|
| [install-steps.md](install-steps.md) | 完整安装文档（架构、配置、故障排查） |
| [values.yaml](values.yaml) | Helm values：MinIO 本地存储方案 |
| [values-s3.yaml](values-s3.yaml) | Helm values：外部 S3 方案（生产推荐） |

## 手动安装（不用脚本时）

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm upgrade --install loki grafana/loki \
  -n monitoring \
  --values values.yaml \
  --set loki.auth_enabled=false
```

## 与其他组件的关系

- **Alloy** ([../observability/alloy.yaml](../observability/alloy.yaml)) 通过 OTLP HTTP 推送日志到 `loki-gateway.monitoring.svc:80/otlp`
- **Grafana** ([../observability/grafana-values.yaml](../observability/grafana-values.yaml)) 通过 `loki-gateway.monitoring.svc:80` 查询日志
- 日志 → Trace 跳转配置见 [../observability/README.md](../observability/README.md#应用接入)
