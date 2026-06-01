# Harbor

Harbor 镜像仓库 Helm Values 配置 — **业务自部署 Harbor**(老的 `harbor.iot.store` 系列业务镜像)。

## 跟仓库主线的关系

| 角色 | 地址 | 用途 |
|---|---|---|
| **镜像拉取入口**(主线) | `dockerhub.ihome.sxxpqp.top:8443` | docker.io / ghcr / quay / k8s.io 全栈代理(pull-through cache),**不接受 push** |
| **镜像推送**(主线) | `registry.cn-hangzhou.aliyuncs.com/sxxpqp/` | 自构建镜像统一推阿里云 ACR |
| **业务 Harbor**(本目录管理的) | `harbor.iot.store:8085` | 老业务镜像 `turing-kubesphere/*` 系列,**新镜像不要往这里推** |

详见仓库根 `CLAUDE.md` 的 "Harbor 架构" / "历史 / 弃用" 段落。

## 文件说明

| 文件 | 说明 |
|---|---|
| [values.yaml](values.yaml) | Harbor Helm 部署 values 配置 |
