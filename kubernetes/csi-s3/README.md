# CSI S3

S3 对象存储 CSI 驱动，将对象存储挂载为 K8s PV。

## 文件说明

| 文件 | 说明 |
|---|---|
| [csi-s3.yaml](csi-s3.yaml) | CSI S3 驱动部署 YAML |
| [driver.yaml](driver.yaml) | CSIDriver 定义：ru.yandex.s3.csi，attachRequired=false，podInfoOnMount=true |
| [provisioner.yaml](provisioner.yaml) | CSI Provisioner 部署 |
| [secret.yaml](secret.yaml) | S3 访问密钥 Secret |
| [storageclass.yaml](storageclass.yaml) | S3 存储类 StorageClass 定义 |
| [pvc.yaml](pvc.yaml) | PVC 示例声明 |
| [pod.yaml](pod.yaml) | 挂载 S3 卷的 Pod 示例 |
