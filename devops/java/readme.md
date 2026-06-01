# Java 流水线

Java 项目 Jenkins Pipeline：Maven 构建 → Docker 镜像 → 推送阿里云 ACR → 更新 K8s Deployment。

## Jenkins Job 参数配置

在 Jenkins job 的「参数化构建」里填入以下值：

| 参数名 | 值 | 说明 |
|---|---|---|
| `REGISTRY` | `registry.cn-hangzhou.aliyuncs.com` | 阿里云 ACR 地址 |
| `DOCKERHUB_NAMESPACE` | `sxxpqp` | ACR 命名空间 |
| `APP_NAME` | 如 `turingcloud-safety` | 应用名（决定镜像名和 Deployment 名） |
| `PORT` | `80` | 容器端口 |
| `NODE_PORT` | 如 `34008` | NodePort（可选） |

## 文件

| 文件/目录 | 说明 |
|---|---|
| [jenkinsfile](jenkinsfile) | Pipeline 脚本（Maven 构建 + Docker 推送 + kubectl apply） |
| [Dockerfile](Dockerfile) | Java 应用镜像构建 |
| [host-cluster/](host-cluster/) | host-cluster 各环境 pod yaml（saas / sd / test / tzj / whrr） |
| [huawei-saas-cluster/](huawei-saas-cluster/) | 华为云 saas 集群 pod yaml |
| [huawei-saas-cluster-ggjc/](huawei-saas-cluster-ggjc/) | 华为云 saas-ggjc 集群 pod yaml |
| [tsl-cluster/](tsl-cluster/) | tsl 集群 pod yaml |
| [ztwx-cluster/](ztwx-cluster/) | ztwx 集群 pod yaml |
