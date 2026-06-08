# JVM 生产配置实践（K8s + VPA 场景）

## 一、背景

在 Kubernetes 环境中运行 Java 应用，配合 VPA（Vertical Pod Autoscaler）进行资源管理时，需要让 JVM 能正确感知容器资源限制，并合理分配堆内存。

VPA 工作原理：

```
VPA 观测历史资源使用
        ↓
生成推荐值 (request / limit)
        ↓
updateMode 决定是否自动重建 Pod
        ↓
Pod 重建后，新的 limit 生效
        ↓
JVM 启动时读取容器 limit → 计算堆大小
```

**关键点**：VPA 不会动态热更新 JVM 内存，只在 Pod 重建时生效。

---

## 二、推荐配置

### ConfigMap（精简版 - 推荐）

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: jvm-config
  namespace: dsp-uat
data:
  JAVA_TOOL_OPTIONS: >-
    -XX:+UseContainerSupport
    -XX:MaxRAMPercentage=75.0
    -XX:InitialRAMPercentage=50.0
    -XX:+UseG1GC
    -XX:MaxGCPauseMillis=200
    -XX:MaxMetaspaceSize=512m
    -XX:+ExitOnOutOfMemoryError
    -Dfile.encoding=UTF-8
```

### ConfigMap（带 GC 日志版 - 可选）

如果需要排查能力，加上 GC 日志输出到 stdout：

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: jvm-config
  namespace: dsp-uat
data:
  JAVA_TOOL_OPTIONS: >-
    -XX:+UseContainerSupport
    -XX:MaxRAMPercentage=75.0
    -XX:InitialRAMPercentage=50.0
    -XX:+UseG1GC
    -XX:MaxGCPauseMillis=200
    -XX:MaxMetaspaceSize=512m
    -XX:+ExitOnOutOfMemoryError
    -Xlog:gc*:stdout:time,level,tags
    -Dfile.encoding=UTF-8
```

---

## 三、参数详解

| 参数 | 作用 | 必要性 |
|------|------|--------|
| `-XX:+UseContainerSupport` | 让 JVM 感知容器资源限制（cgroup） | **必须** |
| `-XX:MaxRAMPercentage=75.0` | 堆最大占容器内存的百分比 | **必须** |
| `-XX:InitialRAMPercentage=50.0` | 堆初始占容器内存的百分比 | 推荐 |
| `-XX:+UseG1GC` | 使用 G1 垃圾回收器 | 推荐 |
| `-XX:MaxGCPauseMillis=200` | GC 暂停目标时间 200ms | 推荐 |
| `-XX:MaxMetaspaceSize=512m` | 限制元空间大小，防止泄漏撑爆容器 | **推荐** |
| `-XX:+ExitOnOutOfMemoryError` | OOM 时直接退出，让 K8s 重启 | **必须** |
| `-Dfile.encoding=UTF-8` | 字符编码 | **必须** |

---

## 四、内存规划

### 内存分配公式

```
容器 Limit = 堆内存 (MaxRAMPercentage%)
           + Metaspace (MaxMetaspaceSize)
           + CodeCache (~256m)
           + 线程栈 (线程数 × 512k~1m)
           + Direct Memory
           + JVM 自身开销
           + 安全余量 (10~15%)
```

### 示例（容器 Limit = 2Gi）

| 区域 | 大小 |
|------|------|
| 堆（75%） | ~1331 MB |
| Metaspace（上限） | 512 MB |
| 其他（CodeCache + 栈 + Direct） | ~300 MB |
| **合计** | **~2143 MB** |

⚠️ 注意：超出 Limit 会被 OOM Kill，建议：
- 容器 Limit 设为 **2.5Gi** 留余量
- 或将 `MaxRAMPercentage` 降到 **60-65%**

---

## 五、Deployment 配置示例

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: your-app
  namespace: dsp-uat
spec:
  template:
    spec:
      containers:
      - name: app
        image: your-image:tag
        envFrom:
        - configMapRef:
            name: jvm-config
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
          limits:
            memory: "2Gi"     # VPA 会动态调整
            cpu: "1"
```

---

## 六、VPA 配置

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: your-app-vpa
  namespace: dsp-uat
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: your-app
  updatePolicy:
    updateMode: "Auto"          # UAT 用 Auto，生产建议 Initial 或 Off
  resourcePolicy:
    containerPolicies:
    - containerName: app
      minAllowed:
        memory: "512Mi"         # 防止缩容过激导致 OOM
        cpu: "100m"
      maxAllowed:
        memory: "4Gi"           # 上限保护
        cpu: "2"
      controlledResources: ["memory", "cpu"]
```

### VPA updateMode 对比

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| `Off` | 只推荐，不修改 | 生产观察期 |
| `Initial` | 仅在 Pod 创建时应用推荐 | 生产推荐 |
| `Auto` / `Recreate` | 自动重建 Pod 应用推荐 | UAT / 非核心服务 |

---

## 七、注意事项

### 1. JAVA_TOOL_OPTIONS 启动提示

使用 `JAVA_TOOL_OPTIONS` 时，JVM 启动会输出：

```
Picked up JAVA_TOOL_OPTIONS: -XX:+UseContainerSupport ...
```

这是正常的，不是错误。

### 2. VPA minAllowed 必须设置

不设置 `minAllowed` 时，VPA 可能将内存缩容到 JVM 无法正常运行的水平。

### 3. OOM 处理策略

- `-XX:+ExitOnOutOfMemoryError`：OOM 后直接退出 → K8s 重启 → 不会僵死
- 不开启此参数时，JVM 可能进入半死不活的状态，无法服务但也不重启

### 4. Heap Dump 持久化（如需要）

默认配置**不保留** heap dump。如需排查 OOM，需挂载持久卷：

```yaml
JAVA_TOOL_OPTIONS: >-
  ...
  -XX:+HeapDumpOnOutOfMemoryError
  -XX:HeapDumpPath=/dumps/
  ...

volumeMounts:
- name: heapdump
  mountPath: /dumps
volumes:
- name: heapdump
  persistentVolumeClaim:
    claimName: heapdump-pvc
```

⚠️ Heap dump 文件大小 ≈ 堆使用量，PVC 容量建议至少 **堆大小 × 3**。

---

## 八、配置 Checklist

部署前确认：

- [ ] `UseContainerSupport` 已启用
- [ ] `MaxRAMPercentage` 在 60-75% 之间
- [ ] `MaxMetaspaceSize` 已设置
- [ ] `ExitOnOutOfMemoryError` 已启用
- [ ] 容器 `limits.memory` 已设置
- [ ] VPA `minAllowed.memory` 已设置（如使用 VPA）
- [ ] VPA `maxAllowed.memory` 已设置（如使用 VPA）
- [ ] 文件编码 UTF-8 已指定

---

## 九、参考命令

### 查看 JVM 实际使用的参数

```bash
kubectl exec -it <pod> -n dsp-uat -- jcmd 1 VM.flags
```

### 查看 JVM 内存使用

```bash
kubectl exec -it <pod> -n dsp-uat -- jcmd 1 VM.native_memory summary
```

### 查看 VPA 推荐值

```bash
kubectl describe vpa your-app-vpa -n dsp-uat
```

### 查看 GC 日志（已开启 -Xlog:gc）

```bash
kubectl logs <pod> -n dsp-uat | grep GC
```