# NFS CSI 驱动（阿里云环境）

K8s 动态挂载 NFS，NFS server 地址：`172.16.0.107`，共享路径：`/mnt/nfs`。

与 `csi-driver-nfs/` 结构相同，仅 StorageClass 里的 server/share 不同（阿里云 ECS 内网 NFS 挂载点）。

## 文件

| 文件 | 说明 |
|---|---|
| [installcsi-nfs.sh](installcsi-nfs.sh) | 一键安装脚本 |
| [csi-nfs-driver.yaml](csi-nfs-driver.yaml) | CSI Driver 定义 |
| [csi-nfs-controller.yaml](csi-nfs-controller.yaml) | Controller 部署 |
| [csi-nfs-node.yaml](csi-nfs-node.yaml) | Node 插件 DaemonSet |
| [rbac-csi-nfs.yaml](rbac-csi-nfs.yaml) | RBAC 权限 |
| [csi-nfs-storageclass.yaml](csi-nfs-storageclass.yaml) | StorageClass（server: 172.16.0.107, share: /mnt/nfs） |

## NFS 服务端 exports 配置

```
/mnt/nfs *(rw,sync,no_subtree_check,no_root_squash)
```

## 镜像加速

CSI 镜像来自 `registry.k8s.io`，containerd 需配置加速源，模板在 `../../CLAUDE.md` 的 "Containerd" 段。
