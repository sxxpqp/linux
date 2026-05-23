# Rook Ceph

Rook Ceph 存储集群部署。

## 文件说明

| 文件 | 说明 |
|---|---|
| [cluster.yaml](cluster.yaml) | CephCluster CRD 定义：rook-ceph 命名空间，Ceph 集群配置（mon/mgr/osd） |
| [changeimage.sh](changeimage.sh) | Ceph 镜像替换脚本（用于离线环境或自定义镜像仓库） |
