# CI/CD 流水线

Jenkins on K8s 流水线配置，Java/Node.js 项目构建部署。

## 文件/目录说明

| 目录/文件 | 说明 | 状态 |
|---|---|---|
| [jenkins.yaml](jenkins.yaml) | Jenkins JCasC ConfigMap（KubeSphere DevOps）：Kubernetes Cloud 动态 Agent 配置、Pod 模板（base/jnlp 容器）、节点亲和性（ci 节点）、Docker socket 挂载、资源限制 | ✅ 生产验证 |
| [jenkinsfile](jenkinsfile) | 通用 Jenkins Pipeline 脚本 | ✅ 生产验证 |
| [java/](java/) | Java 项目流水线：Maven 构建 Dockerfile、Jenkinsfile 脚本、环境变量配置（端口、镜像仓库、应用名） | ✅ 生产验证 |
| [nodejs/](nodejs/) | Node.js 项目流水线：NPM 构建 Dockerfile、Nginx 配置、Jenkinsfile 脚本、多分支环境变量（zktl/gongga/tsl 等） | ✅ 生产验证 |
| [turingcloud-device/](turingcloud-device/) | TuringCloud 设备服务 Jenkinsfile + Pod Template YAML | ✅ 生产验证 |
| [turingcloud-web/](turingcloud-web/) | TuringCloud Web 服务 Jenkinsfile | ✅ 生产验证 |
| [docker-build/](docker-build/) | Docker 镜像构建相关 | 验证过 |
| [gitlab/](gitlab/) | GitLab CI/CD 集成配置 | 验证过 |
