# Helm

Helm 安装与常用命令。

## 文件

| 文件 | 说明 |
|---|---|
| [install-helm.sh](install-helm.sh) | 离线安装 Helm（从 chfs 下载，当前版本 v4.1.0） |

## 常用命令

```bash
# 渲染模板（不 apply，用于查看最终 YAML）
helm template <release> <chart> > output.yaml

# 例：渲染 neo4j chart
helm template saas-milvus neo4j/neo4j > neo4j_manifest.yaml
```
