# 证书管理

Kubernetes 集群证书轮换与维护。

## 文件说明

### 生产(3 master HA,长期主力)

| 文件 | 说明 |
|---|---|
| [k8s-cert-rotation.sh](k8s-cert-rotation.sh) | **3 master 生产脚本**:整目录备份 + etcd 快照 + renew + 轮询重启 + 等 etcd 3/3 healthy。每台 master 独立跑一次,串行 |
| [k8s-cert-rotation-3masters.md](k8s-cert-rotation-3masters.md) | **3 master 完整手册**:原理 / 影响范围 / 前置备份 / 串行更新 / 每节点验证 / 整体验证 / 回滚 / 常见坑 / 监控告警 |

### 测试 / 单机(脚本验证用)

| 文件 | 说明 |
|---|---|
| [k8s-cert-rotation-single.sh](k8s-cert-rotation-single.sh) | **单 master 测试脚本**:一键跑完前置检查 + 备份 + 续证 + 4 pod 轮询重启 + 验证。带强校验(检测到多 master 会拒绝运行) |
| [k8s-cert-rotation-single-master.md](k8s-cert-rotation-single-master.md) | **单 master 文档**:跟 3 节点版的差异对照、完整流程、验证、回滚(含 etcd snapshot 恢复)、从单机经验迁移到 3 节点要注意什么 |
