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

### 跨 Namespace 更新 TLS Secret

[update-tls-secret-all-namespaces.sh](update-tls-secret-all-namespaces.sh)：遍历全部 Namespace，仅更新已经存在且类型为 `kubernetes.io/tls` 的 `wishfox` Secret（可通过 `SECRET_NAME` 修改名称）。**默认只预览**，加 `--apply` 才会写入；正式更新前逐个备份 Secret JSON（包含私钥，请安全保存）。

```bash
# 先检查当前 kubectl context，并预览匹配对象
kubectl config current-context
bash kubernetes/cert/update-tls-secret-all-namespaces.sh \
  --cert /path/fullchain.pem --key /path/privkey.pem

# 核对预览结果后，明确授权实际更新
BACKUP_DIR=./tls-backup-$(date +%Y%m%d-%H%M%S) \
bash kubernetes/cert/update-tls-secret-all-namespaces.sh \
  --cert /path/fullchain.pem --key /path/privkey.pem --apply
```

> 需要读取 Namespace 和 Secret，以及更新 Secret 的 RBAC 权限。脚本验证证书与私钥匹配；跳过不存在的 Secret，不会新建。生产环境先在测试集群验证；更新后还需确认 Ingress/应用实际加载了新证书。备份目录不要提交到 Git。
