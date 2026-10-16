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

[update-tls-secret-all-namespaces.sh](update-tls-secret-all-namespaces.sh)：把一份新证书和私钥，更新到各 Namespace 中已有的同名 TLS Secret。默认名称是 `wishfox`，可以通过 `SECRET_NAME` 修改。

**运行过程：检查证书 → 显示目标集群 → 查找已有 Secret → 先备份 → 原地更新。默认只预览，加 `--apply` 才修改。**

| 情况 | 脚本怎么处理 |
|---|---|
| 没有这个 Secret，或类型不是 TLS | 跳过，不新建、不删除 |
| 已经是相同证书和私钥 | 跳过，避免重复更新 |
| 新证书过期、尚未生效，或私钥不匹配 | 停止，不更新任何 Secret |
| Secret 不允许修改（immutable） | 报错并保留原样 |
| 更新前备份失败 | 不更新这个 Secret |
| 查询后 Secret 被删除、重建或修改 | 本次更新失败，不覆盖别人的修改、不重新创建对象 |
| 需要更新时 | 默认在固定主目录 `./tls-secret-backups/` 下生成 `run-时间-随机串` 子目录，保存各 Namespace 的完整 Secret YAML（如 `default-wishfox.yaml`）；全部跳过时不创建空目录 |

依赖：Bash、kubectl、openssl、GNU date（Linux / Git Bash），**不需要 jq**。使用当前 kubeconfig，可用 `--context` 指定目标集群；执行过程中固定该 context。

这里更新的是**快过期的旧证书**，`--cert` 和 `--key` 要填写**续签后的新证书和新私钥**。脚本不要求旧证书仍然有效，也不会因为旧证书快过期而拒绝更新；有效期检查针对传入的新证书。脚本本身不申请或续签证书。

```bash
# 先检查当前 kubectl context，并预览匹配对象
kubectl config current-context
bash kubernetes/cert/update-tls-secret-all-namespaces.sh \
  --cert /path/fullchain.pem --key /path/privkey.pem

# 核对 context 和预览名单后，正式更新（证书和私钥须是对应域名的一套文件）
BACKUP_DIR=./tls-secret-backups \
bash kubernetes/cert/update-tls-secret-all-namespaces.sh \
  --cert /path/fullchain.pem --key /path/privkey.pem --apply
```

需要 `list namespaces`、`get secrets`、`patch secrets` 权限。每个 Secret 的证书和私钥通过同一个请求一起替换，保留名称、UID、标签、注解和其他数据。多个 Namespace 逐个更新，不是跨 Namespace 的整体事务；有失败时会返回非零状态，不会自动回滚已成功的对象。

**关于不停机：**脚本不删除 Secret、不重启 Pod，也不改 Service 或 Ingress 路由，因此不会主动中断业务。Ingress 控制器或应用必须支持监听 Secret 并热加载证书，才能在不重启的情况下完成切换。环境变量中的 Secret 不会自动刷新；通过 `subPath` 挂载的 Secret 文件也不会自动更新。普通 Secret 卷更新有传播延迟，应用仍需重新读取文件。[Kubernetes 官方说明](https://kubernetes.io/docs/concepts/configuration/secret/)

正式执行前确认新证书覆盖业务域名、证书链完整，且旧证书尚未过期。脚本检查第一张证书的有效期和密钥匹配，不代替公网信任链或域名验证。若 cert-manager 等控制器管理这个 Secret，应通过原控制器续证，避免手工更新被覆盖。

更新后，**到实际 HTTPS 入口确认对外证书**，不要只看 Secret 更新成功：

```bash
# 将 example.com 换成业务域名；如有多个入口 IP，应逐个检查。
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null |
  openssl x509 -noout -subject -issuer -dates -fingerprint -sha256

# 与本地新证书的指纹比较
openssl x509 -in /path/fullchain.pem -noout -fingerprint -sha256
```

备份 YAML 包含私钥，不要提交到 Git。Linux 下目录权限为 700、文件权限为 600；Windows 还需通过 NTFS 权限保护备份。恢复时同样应原地更新证书数据，不要先删除 Secret。
