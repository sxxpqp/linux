# rancher

K8s 集群管理面板 Rancher 的 docker-compose 启停模板。

- `docker-compose.yaml` — 主部署
- `start.sh` / `stop.sh` / `restart.sh` — 启停脚本

## ⚠ 状态待确认

仓库主线已经迁到 **KubeBlocks + kubeadm** (见 `kubernetes/kubeblocks/` 和 `kubernetes/kubeadm/`),Rancher 是否还在跑、是否还需要维护,**未确认**。

下次到现场确认:
- 如果还在用 → 留在此处,补一段"管的是哪个集群、UI 入口域名"
- 如果已停 → `git mv rancher archived/rancher`,跟 clash 一样归档
