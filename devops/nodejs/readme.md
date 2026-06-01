# Node.js 流水线

Node.js 项目 Jenkins Pipeline：NPM 构建 → Nginx 镜像 → 推送阿里云 ACR → 更新 K8s Deployment。

## Jenkins Job 参数配置

在 Jenkins job 的「参数化构建」里填入以下值：

| 参数名 | 值 | 说明 |
|---|---|---|
| `REGISTRY` | `registry.cn-hangzhou.aliyuncs.com` | 阿里云 ACR 地址 |
| `DOCKERHUB_NAMESPACE` | `sxxpqp` | ACR 命名空间 |
| `APP_NAME` | `turingcloud-web` | 应用名 |
| `PORT` | `80` | 容器端口 |
| `BRANCH_NAME` | `zktl` / `gongga` / `tsl` / `ztwx` / `tezhijia` | 分支对应环境，决定镜像 tag 和部署目标 |

## 文件

| 文件/目录 | 说明 |
|---|---|
| [jenkinsfile](jenkinsfile) | Pipeline 脚本（NPM 构建 + Docker 推送 + kubectl apply） |
| [Dockerfile](Dockerfile) | Node.js 应用镜像（Nginx 静态服务） |
| [nginx.conf](nginx.conf) | Nginx 配置 |
| [deploy/](deploy/) | 各环境 pod yaml（gstest / huawei-saas / saas / sd / test / tsl / tzj / whrr / ztwx） |
