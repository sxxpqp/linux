# NFS CSI 驱动（通用）

K8s 动态挂载 NFS，NFS server 地址：`172.16.0.196`，共享路径：`/srv/nfs`。

## 文件

| 文件 | 说明 |
|---|---|
| [installcsi-nfs.sh](installcsi-nfs.sh) | 一键安装脚本 |
| [csi-nfs-driver.yaml](csi-nfs-driver.yaml) | CSI Driver 定义 |
| [csi-nfs-controller.yaml](csi-nfs-controller.yaml) | Controller 部署 |
| [csi-nfs-node.yaml](csi-nfs-node.yaml) | Node 插件 DaemonSet |
| [rbac-csi-nfs.yaml](rbac-csi-nfs.yaml) | RBAC 权限 |
| [csi-nfs-storageclass.yaml](csi-nfs-storageclass.yaml) | StorageClass（server: 172.16.0.196, share: /srv/nfs） |

## NFS 服务端 exports 配置

```
/srv/nfs *(rw,sync,no_subtree_check,no_root_squash)
```

## 镜像加速

CSI 镜像来自 `registry.k8s.io`，containerd 需配置加速源，模板在 `../../CLAUDE.md` 的 "Containerd" 段。
