# Tekton CI/CD

Tekton Pipeline + Dashboard 部署配置。✅ 生产验证

## 文件

| 文件 | 说明 |
|---|---|
| [release.yaml](release.yaml) | Tekton Pipelines 核心组件 |
| [dashboard-release.yaml](dashboard-release.yaml) | Tekton Dashboard（精简版） |
| [dashboard-release-full.yaml](dashboard-release-full.yaml) | Tekton Dashboard（完整版） |
| [git-clone.yaml](git-clone.yaml) | git-clone Task |
| [source-to-image.yaml](source-to-image.yaml) | source-to-image Task |

## Pipeline 访问 Registry 的 Secret

Tekton Task 拉/推镜像需要把 registry 凭据注入为 `docker-config` Secret：

```bash
# 以阿里云 ACR 为例（替换 USERNAME / PASSWORD）
kubectl create secret docker-registry acr-secret \
  --docker-server=registry.cn-hangzhou.aliyuncs.com \
  --docker-username=[USERNAME] \
  --docker-password=[PASSWORD] \
  --dry-run=client -o json \
  | jq -r '.data.".dockerconfigjson"' | base64 -d > /tmp/config.json \
  && kubectl create secret generic docker-config --from-file=/tmp/config.json \
  && rm -f /tmp/config.json

# 验证
kubectl get secret docker-config -o jsonpath='{.data.config\.json}' | base64 -d
```
