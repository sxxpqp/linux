# Kubernetes 本地盘规划(Local PV / local-path / Longhorn)

> 目的:给 **MySQL / Redis / Kafka / RocketMQ** 这类有状态服务选本地盘方案时,快速决定该用什么、目录怎么拆、`/DATA` 怎么挂。

---

## 结论先说

### 1. 高性能 / 低延迟优先级

| 方案 | 延迟 | IOPS | 故障恢复 | 推荐场景 |
|---|---|---|---|---|
| **Local PV(原生本地卷)** | **最好** | **最好** | 最弱(节点坏了卷不漂移) | **MySQL / Kafka 首选**,Redis 也适合 |
| **local-path-provisioner** | 接近 Local PV | 接近 Local PV | 弱 | 测试 / 开发;生产可用,但要自己收紧规范 |
| **Longhorn strict-local + 1 副本** | 次优 | 次优 | 中等 | Redis / 一般中间件可用 |
| **Longhorn 普通多副本** | 最差 | 最差 | 最好 | 先保可用,不追极致性能 |

### 2. 中间件选型建议

| 中间件 | 推荐存储 |
|---|---|
| **MySQL(MGR / 主从 / KubeBlocks MySQL)** | **Local PV 优先** |
| **Redis Sentinel / Redis Cluster** | Local PV 优先;Longhorn strict-local 1 副本次选 |
| **Kafka** | **Local PV 优先** |
| **RocketMQ / RabbitMQ** | Local PV 优先 |

一句话:

- **要极致性能**:选 **Local PV**
- **要省事一点**:可以先上 `local-path`,但别拿默认配置裸跑生产数据库
- **要存储层高可用**:才考虑 Longhorn,但性能不是第一名

---

## Local PV 是怎么工作的

Local PV 不是分布式存储,而是:

1. 先把节点本地盘挂到固定目录
2. 把这个目录/盘声明成一个 `PersistentVolume`
3. 用 `nodeAffinity` 写死这个 PV 属于哪台节点
4. Pod 通过 PVC 使用这个 PV
5. 调度器会把 Pod 调度到这块盘所在节点

所以它的本质是:

```text
本地磁盘 -> PV(local.path=/DATA/xxx) -> PVC -> Pod
```

不是:

```text
Pod -> 网络存储 -> 远端副本
```

### 最小可运行例子

假设:

- 节点名:`k8sw1.sohuglobal`
- 本地盘已挂到:`/DATA/mysql01`
- 目标:给一个测试 Pod 挂 20Gi 本地卷

#### 1. StorageClass

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-ssd
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
```

#### 2. PersistentVolume

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv-mysql01
spec:
  capacity:
    storage: 20Gi
  volumeMode: Filesystem
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-ssd
  local:
    path: /DATA/mysql01
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - k8sw1.sohuglobal
```

#### 3. PersistentVolumeClaim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: local-ssd
  resources:
    requests:
      storage: 20Gi
```

#### 4. 测试 Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pvc-test
spec:
  restartPolicy: Never
  containers:
  - name: test
    image: busybox:1.36
    command: ["sh", "-c", "echo hello-local-pv > /data/test.txt && sleep 36000"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: mysql-data
```

#### 5. 验证

```bash
kubectl get sc
kubectl get pv
kubectl get pvc
kubectl get pod pvc-test -o wide
kubectl exec -it pvc-test -- sh
ls -l /data
cat /data/test.txt
```

结果:

- PVC 会绑定到 `local-pv-mysql01`
- Pod 会被调度到 `k8sw1.sohuglobal`
- 因为 `PV.nodeAffinity` 已经把这块卷锁定在该节点

---

## 多个 MySQL / Redis / Kafka / MQ,要不要建多个目录

**要。**

但要分两层理解:

### 1. 目录必须拆

不要所有服务都塞到一个:

```text
/DATA
```

至少要拆成:

```text
/DATA/mysql
/DATA/redis
/DATA/kafka
/DATA/rocketmq
```

如果同一类服务有多套集群,继续往下拆:

```text
/DATA/mysql/prod-mgr-a
/DATA/mysql/prod-mgr-b
/DATA/redis/cache-a
/DATA/redis/cache-b
/DATA/kafka/cluster-a
/DATA/rocketmq/mq-a
```

### 2. 高性能场景最好连磁盘也拆

如果你是真的跑生产 MySQL / Kafka,**只拆目录还不够**。  
更推荐:

```text
/dev/sdb -> /DATA/mysql01
/dev/sdc -> /DATA/mysql02
/dev/sdd -> /DATA/mysql03
```

或者:

```text
/dev/nvme0n1 -> /DATA/kafka01
/dev/nvme1n1 -> /DATA/kafka02
/dev/nvme2n1 -> /DATA/kafka03
```

这样做的好处:

- IO 隔离清楚
- 容量边界清楚
- 故障定位清楚
- 不会几个重型中间件抢同一个文件系统

---

## `/DATA` 推荐怎么挂

### 不推荐

不推荐把所有盘都混成一个大目录再让所有中间件共用:

```text
/DATA
```

原因:

- 容量不好控
- 容易互相抢 IO
- 一个服务写爆影响全体
- 后面清理、迁移、排障都麻烦

### 推荐

推荐把 `/DATA` 作为统一根目录,但每块盘独立挂载:

```text
/DATA/mysql01
/DATA/mysql02
/DATA/mysql03
/DATA/redis01
/DATA/redis02
/DATA/kafka01
/DATA/kafka02
/DATA/kafka03
/DATA/rocketmq01
```

如果盘没那么多,退一步也至少做到“按中间件拆目录”:

```text
/DATA/mysql/prod-a
/DATA/mysql/prod-b
/DATA/redis/cache-a
/DATA/kafka/cluster-a
```

---

## Local PV 和 local-path 的区别

| 项 | Local PV | local-path |
|---|---|---|
| 调度感知 | **强**(`nodeAffinity`) | 一般 |
| 建模方式 | 明确 PV / PVC / 节点绑定 | provisioner 自动建本地目录 |
| 性能 | **最好** | 接近 Local PV |
| 规范性 | **最好** | 偏轻量 |
| 适合数据库 | **最推荐** | 可用,但要自己约束 |

### Local PV

适合:

- MySQL
- Kafka
- Redis 持久化
- RocketMQ

特点:

- 调度器明确知道卷在哪台节点
- 更适合 StatefulSet / Operator
- 更适合生产数据库

### local-path

适合:

- 测试 / 开发
- 对路径短有要求,但不想手工建一堆 PV
- 中小规模生产,且团队能接受“本地目录 provisioner”的边界

注意:

- 默认 `reclaimPolicy: Delete` 对数据库不友好
- 默认目录 `/opt/local-path-provisioner` 不适合直接上生产
- 生产要改成专用目录,比如 `/DATA/local-path`

---

## 如果坚持用 local-path,生产至少这样收紧

### StorageClass

- `volumeBindingMode: WaitForFirstConsumer`
- `reclaimPolicy: Retain`

### 数据目录

不要默认:

```text
/opt/local-path-provisioner
```

改成:

```text
/DATA/local-path/mysql
/DATA/local-path/redis
/DATA/local-path/kafka
/DATA/local-path/rocketmq
```

更进一步可以按节点定制:

```json
{
  "nodePathMap": [
    {
      "node": "mysql-node-1",
      "paths": ["/DATA/local-path/mysql"]
    },
    {
      "node": "redis-node-1",
      "paths": ["/DATA/local-path/redis"]
    },
    {
      "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
      "paths": ["/DATA/local-path/default"]
    }
  ]
}
```

### 适用边界

- **MySQL**:能跑,但不如 Local PV 规范
- **Redis**:可用
- **Kafka**:不如 Local PV 干净
- **Longhorn 性能不够时的过渡方案**:可考虑

---

## 为什么说后期迁移会更麻烦

**对,会更麻烦。**

不管是 `Local PV` 还是 `local-path`,本质上都和**节点本地磁盘强绑定**。  
这类方案的代价就是:

- 节点坏了,卷不会自动漂移
- 想换节点,通常要手工迁数据
- 想扩容磁盘,经常要重新规划目录/PV
- 想从一台机器搬到另一台机器,不是改个 StorageClass 就完了

### 典型麻烦点

| 场景 | Local PV / local-path | Longhorn / NFS / Ceph |
|---|---|---|
| 节点宕机 | Pod 很可能起不来,得人工接管 | 更容易自动恢复 |
| 换节点 | 要迁目录/数据,重建 PV | 相对容易 |
| 扩盘 | 往往要新盘、新目录、新 PV | 通常更平滑 |
| 集群迁移 | 需要导数据 + 重建卷对象 | 相对简单 |

### 为什么还能选它

因为你拿它换的是:

- 更低延迟
- 更高 IOPS
- 更短数据路径

所以这是一个明确 trade-off:

> **Local PV / local-path 用“后期迁移麻烦”换“当前性能最好”。**

### 什么时候值得

- MySQL / Kafka / Redis 确实吃性能
- 节点规划比较稳定,不是三天两头挪机器
- 团队能接受手工迁移数据
- 应用本身有高可用机制(MGR / Redis Cluster / Kafka 副本)

### 什么时候不值得

- 节点经常变
- 经常要迁服务
- 更看重存储层自动恢复
- 团队不想碰数据迁移

### 迁移时通常要做什么

以 `Local PV` 为例,一般是:

1. 新节点准备新盘和新目录
2. 停业务或切只读
3. `rsync` / 备份恢复 / 应用级同步把旧数据导到新节点
4. 新建 PV
5. 重新绑 PVC 或重建实例
6. 启动并校验

所以它和 Longhorn 的思路完全不同:

- `Local PV` 更像“本地盘编排”
- Longhorn 更像“分布式存储”

---

## Local PV 的推荐目录布局

### MySQL 3 节点

```text
node1: /DATA/mysql01
node2: /DATA/mysql02
node3: /DATA/mysql03
```

每个目录对应 1 个 PV,每个 MySQL 实例绑定 1 个 PVC。

### Redis Cluster(3 主 3 从)

```text
node1: /DATA/redis01 /DATA/redis02
node2: /DATA/redis03 /DATA/redis04
node3: /DATA/redis05 /DATA/redis06
```

主从用反亲和拆开,不要主从同节点。

### Kafka 3 broker

```text
node1: /DATA/kafka01
node2: /DATA/kafka02
node3: /DATA/kafka03
```

每个 broker 1 个独立 PV,不要跟 MySQL 混盘。

---

## 是否需要为每套中间件建多个目录

### 推荐答案

| 场景 | 建议 |
|---|---|
| 同时有 MySQL / Redis / Kafka / MQ | **至少按中间件拆目录** |
| 同一种中间件有多套集群 | **再按集群拆目录** |
| 高性能生产 | **最好按磁盘/实例拆挂载点** |

### 推荐命名

```text
/DATA/mysql/prod-mgr-a
/DATA/mysql/prod-mgr-b
/DATA/redis/cache-a
/DATA/redis/cache-b
/DATA/kafka/cluster-a
/DATA/rocketmq/prod-a
```

如果是 Local PV,更推荐直接按实例盘拆:

```text
/DATA/mysql01
/DATA/mysql02
/DATA/mysql03
/DATA/redis01
/DATA/redis02
/DATA/kafka01
/DATA/kafka02
/DATA/kafka03
```

---

## 最终建议

### MySQL

- **首选 `Local PV`**
- 一实例一盘/一路径
- 不建议和 Kafka 混盘

### Redis

- 持久化、性能敏感:优先 `Local PV`
- 一般缓存场景:可以放宽到 `local-path` 或 Longhorn strict-local 1 副本

### Kafka

- **强烈建议 `Local PV`**
- 每个 broker 独立本地盘
- 不推荐 Longhorn 多副本跑高吞吐 Kafka

### RocketMQ / RabbitMQ

- 优先 `Local PV`
- 至少按集群拆目录

---

## 一句话拍板

如果你现在的目标是:

> **高性能 + 低延迟 + 多套 MySQL/Redis/Kafka/MQ 共存**

那推荐方案是:

1. **统一根目录用 `/DATA`**
2. **不要所有服务共用一个 `/DATA` 目录**
3. **至少按中间件/集群拆目录**
4. **高性能服务尽量按磁盘独立挂载点**
5. **MySQL / Kafka 优先 Local PV**
6. **Redis 其次**
7. **Longhorn 放弃“极致性能”诉求时再考虑**
