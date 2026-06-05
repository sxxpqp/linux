# local-path-provisioner 安装

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/local-path/local-path-storage.md
> 状态: 验证过

`local-path` 是一个 Kubernetes StorageClass 插件,把 PV 直接绑到**工作节点本地磁盘**,给应用提供本地存储。Rancher RKE 集群常用。

## 适用场景

- 单节点 / 小集群,不想引入 Ceph / Longhorn 等分布式存储
- 测试 / 开发环境
- 应用本身有数据副本能力(如 etcd / Kafka),不依赖存储层做冗余

## 安装步骤

### 1. 创建命名空间

```bash
kubectl create namespace local-path-storage
```

### 2. 部署 local-path-provisioner

```bash
kubectl apply -f local-path-storage.yaml
```

### 3. 等 Pod ready

```bash
kubectl get pods -n local-path-storage
```

期望看到 `local-path-provisioner-xxx` Pod 状态为 `Running`。

### 4. 查看 StorageClass

```bash
kubectl get storageclass
```

应该看到名为 `local-path` 的 StorageClass。

### 5. 设为默认 StorageClass(可选)

```bash
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

## 测试

### 创建测试 PVC

```bash
kubectl apply -f https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/rancher/local-path-provisioner/blob/master/examples/pvc/pvc.yaml
```

### 创建测试 Pod

```bash
kubectl apply -f https://nexus.ihome.sxxpqp.top:8443/repository/raw-github/rancher/local-path-provisioner/blob/master/examples/pod/pod.yaml
```

### 验证

```bash
kubectl get pods
```

应该看到 `volume-test` Pod 状态为 `Running`。

## 注意事项

> ⚠ 使用 `local-path` 前请确认:
> 1. 所有节点都有本地磁盘
> 2. 所有节点的本地磁盘路径一致(默认 `/opt/local-path-provisioner`,可改 `ConfigMap`)
> 3. **PV 绑定到具体节点之后,Pod 不能再调度到别的节点** — 跨节点的高可用要靠应用层自己做副本
