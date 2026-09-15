# DevOps & CI/CD 模块上下文

> 本目录包含 Jenkins 流水线配置、GitLab CI 模板以及各业务多集群 Kubernetes 部署模板。

## 适用集群与环境矩阵

修改或新建 Pod 模板/部署 YAML 前，**务必先确认目标集群**：

| 集群标识 | 环境/客户说明 | 相关路径 |
|---|---|---|
| `host-cluster` | 宿主/基础服务集群 | `devops/java/host-cluster/` |
| `huawei-saas` / `huawei-saas-cluster` | 华为云预发/生产集群 | `devops/java/huawei-saas-cluster/`, `huawei-saas-cluster-ggjc/` |
| `tsl` / `tsl-cluster` | TSL 环境集群 | `devops/java/tsl-cluster/` |
| `ztwx` / `ztwx-cluster` | ZTWX 环境集群 | `devops/java/ztwx-cluster/` |
| `dsp` | DSP 平台 GitLab CI 流程 | `devops/gitlab-ci/dsp/` |

## 注意事项

1. **配置隔离**：各集群间的 JVM 参数、环境变量及 Ingress 域名各不相同，**切勿将某一个集群的 YAML 强行重构或覆盖到其他集群**。
2. **镜像规范**：构建流水线中产出的镜像统一推送至阿里 ACR 或 Harbor 镜像仓库，YAML 镜像声明按标准维持上游或完整私服路径。
3. **就地修订**：如无明确要求，仅做特定集群与特定服务配置的就地修订，不在此进行大跨度结构重构。
