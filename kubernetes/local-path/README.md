# StorageClass — local-path

将 PV 绑定到节点本地磁盘的轻量 StorageClass，由 Rancher local-path-provisioner 实现。

> **适用场景：测试 / 开发环境**。数据存在单节点本地磁盘，节点故障数据丢失，不适合生产。生产存储推荐 [longhorn/](../longhorn/) 或 [csi-driver-nfs/](../csi-driver-nfs/)。

## 文件

| 文件 | 说明 |
|---|---|
| [local-path-storage.yaml](local-path-storage.yaml) | 一键部署清单（Namespace + RBAC + Deployment + StorageClass），镜像已改走 Harbor 代理 |
| [local-path-storage.md](local-path-storage.md) | 原始部署笔记 |

## 部署

```bash
kubectl apply -f local-path-storage.yaml

# 等 provisioner pod Running
kubectl get pods -n local-path-storage

# 查看 StorageClass
kubectl get storageclass
```

## 设为默认 StorageClass

```bash
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## 验证（创建测试 PVC + Pod）

```bash
# 测试 PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: local-path-test-pvc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 128Mi
EOF

# 测试 Pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: volume-test
spec:
  containers:
  - name: test
    image: busybox
    command: ["sh", "-c", "echo hello > /data/test.txt && sleep 3600"]
    volumeMounts:
    - mountPath: /data
      name: vol
  volumes:
  - name: vol
    persistentVolumeClaim:
      claimName: local-path-test-pvc
EOF

kubectl get pods volume-test
```

## 数据存放路径

默认存在各节点的 `/opt/local-path-provisioner/<pvc-name>/` 下，可在 ConfigMap `local-path-config` 里改路径。
