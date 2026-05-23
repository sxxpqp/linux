# KubeSphere 容器平台

KubeSphere 多集群管理、配置示例与运维。

## 文件说明

| 文件 | 说明 |
|---|---|
| [install.md](install.md) | KubeSphere 安装指南 |
| [config-sample.yaml](config-sample.yaml) | KubeSphere 集群配置示例 |
| [dconfig-sample.yaml](dconfig-sample.yaml) | KubeSphere 配置示例（devops 增强版） |
| [kubesphere-update-masterip.sh](kubesphere-update-masterip.sh) | KubeSphere Master 节点 IP 变更后更新证书与服务 |
| [imagepull.sh](imagepull.sh) | KubeSphere 镜像批量拉取脚本 |
| [tf.md](tf.md) | KubeSphere 技术架构说明 |

## 多集群管理

### Host 集群配置要点

- 在 ks-installer 中设置 `clusterRole: host` 和 `proxyPublishAddress`
- 成员集群设置 `clusterRole: member` 并配置 host 集群的 `jwtSecret`
- 获取成员集群 kubeconfig: `kubectl get cluster [name] -o jsonpath='{.spec.connection.kubeconfig}' | base64 -d`

> **注意**：配置文件中的版本（v3.1.1）和 IP 地址仅供参考，请根据实际版本和环境修改。
