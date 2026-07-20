---
name: k8s-yaml-prod
description: Production-grade Kubernetes YAML standards calibrated to this repo's actual conventions (Jenkins $VARS templating, Harbor imagePullSecrets, tcpSocket probes, multi-cluster overlays under devops/<env>/). Use BEFORE writing or modifying any K8s YAML for production — Deployment / StatefulSet / DaemonSet / Service / Ingress / HPA / PDB / NetworkPolicy / Job / CronJob. Triggers on:写 yaml,写 deployment,写 statefulset,k8s yaml,生产 yaml,业务 pod 模板,加 service,加 ingress,加 hpa,加 networkpolicy,写 cronjob,改副本数,加 probe,加 resources,deploy 模板. Provides必查清单 + 本仓库基线模板 + 各 kind 关键字段 + 反模式。
---

# K8s 生产 YAML 标准

> 项目: https://github.com/sxxpqp/linux
> **不是教科书,是本仓库实际在跑的标准**。模板提取自 `devops/java/host-cluster/saas/pod-saas.yaml` 等真实生产 yaml,补上常被遗漏的项。

## 必查清单(写完前自查 8 项)

| # | 项 | 没做的后果 |
|---|---|---|
| 1 | `resources.requests` + `limits` 都写,CPU + memory | 节点资源争抢,被 OOMKilled,调度不准 |
| 2 | `livenessProbe` + `readinessProbe` 至少各一个 | Pod 假死时不重启 / 流量打到没 ready 的 Pod |
| 3 | `image` 用具体 tag(`:v1.2.3` / `:SNAPSHOT-${BUILD_NUMBER}`),**不用 `:latest`** | 节点缓存的 latest 不一致,回滚没目标 |
| 4 | `imagePullSecrets: harbor-repository` 必带 | 私有 Harbor 拉不到镜像 |
| 5 | `imagePullPolicy`:固定 tag 用 `IfNotPresent`,SNAPSHOT 用 `Always` | 浪费拉取带宽 / 节点缓存了旧镜像 |
| 6 | `terminationGracePeriodSeconds`:HTTP 服务 30,长任务调大 | SIGTERM 后被 SIGKILL,连接没优雅断 |
| 7 | `securityContext`(关键场景):`runAsNonRoot: true` + `allowPrivilegeEscalation: false` | 容器逃逸 / 提权风险 |
| 8 | 顶部注释:`# cluster: x   env: y   namespace: z   type: java/nodejs   last-updated: YYYY-MM-DD` | 多集群版本搞混(`saas / sd / tsl / tzj / whrr / ztwx / huawei-saas / gstest` 8 个) |

## 本仓库基线模板(Deployment + Java/Nodejs 业务)

直接基于 `devops/java/host-cluster/saas/pod-saas.yaml`,补上少的:

```yaml
# cluster: <host-cluster|huawei-saas-cluster|tsl-cluster|ztwx-cluster>
# env: <saas|sd|test|tzj|whrr|tsl|ztwx|huawei-saas|gstest>
# namespace: <tmc-v2 | ...>
# type: <java|nodejs>
# last-updated: YYYY-MM-DD
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: $APP_NAME
  name: $APP_NAME
  namespace: tmc-v2
spec:
  progressDeadlineSeconds: 600
  replicas: 1                          # 生产业务 ≥2;批跑/测试 1
  strategy:                            # ★ 建议加,默认滚更但可控
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0                # 0 = 永不少于现有副本(零中断)
  selector:
    matchLabels:
      app: $APP_NAME
  template:
    metadata:
      labels:
        app: $APP_NAME
    spec:
      containers:
        - name: $APP_NAME
          image: $REGISTRY/$DOCKERHUB_NAMESPACE/$APP_NAME:SNAPSHOT-$BUILD_NUMBER
          imagePullPolicy: Always      # SNAPSHOT tag 用 Always;固定 tag 改 IfNotPresent
          ports:
            - containerPort: $PORT
              protocol: TCP
          resources:
            requests:                  # 调度依据,务必给个真实值
              cpu: 250m
              memory: 1000Mi
            limits:                    # 上限,memory 超了会 OOMKill
              cpu: 4000m
              memory: 4000Mi
          # 推荐 httpGet — 验证到应用层(业务真能响应),比 tcpSocket(只测 TCP 监听)更准
          # 业务必须暴露 /actuator/health/{liveness,readiness}(Spring Boot)或 /healthz(nodejs)
          # 没有健康端点时再退回 tcpSocket(见下方"探针选型"段)
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness   # nodejs 用 /healthz 或 /live
              port: $PORT
              scheme: HTTP                       # HTTPS 接口用 HTTPS + httpHeaders
            initialDelaySeconds: 60              # Java 启动慢,nodejs 30 即可
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 5
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness   # nodejs 用 /ready
              port: $PORT
            initialDelaySeconds: 60
            periodSeconds: 20                    # readiness 比 liveness 稀疏点 OK
            timeoutSeconds: 3
            failureThreshold: 5
          # ★ 建议补:Pod 启动期间不让 liveness 误杀(K8s 1.16+)
          startupProbe:
            httpGet:
              path: /actuator/health/liveness    # 与 liveness 同端点即可
              port: $PORT
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 30                 # 最多 30*10=300s 启动窗口
          # ★ 建议补:优雅停机(配合 terminationGracePeriodSeconds)
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 5"]   # 给 Service endpoint 摘流时间
          # ★ 建议补(关键服务):安全
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false   # 老应用经常写 /tmp,先 false
          terminationMessagePath: /dev/termination-log
          terminationMessagePolicy: File
      imagePullSecrets:
        - name: harbor-repository
      dnsPolicy: ClusterFirst
      restartPolicy: Always
      terminationGracePeriodSeconds: 30
      # ★ 建议补(多副本):打散到不同节点
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway   # 节点少时不卡调度
          labelSelector:
            matchLabels:
              app: $APP_NAME
```

## 探针选型(三选一)

| 探针类型 | 何时用 | 例子 | 注意 |
|---|---|---|---|
| **`httpGet`(首选)** | 应用暴露了 HTTP 健康端点 | `/actuator/health/{liveness,readiness}`(Spring Boot)/ `/healthz` / `/ready` | 探针 hit 算业务请求,确保端点**不依赖 DB / 下游**;依赖了就只能在 readiness 里检 |
| **`tcpSocket`(退回)** | 应用没暴露 HTTP 端点(纯 TCP 服务、第三方镜像不让改) | `tcpSocket: { port: $PORT }` | 只能验证端口在 listen,不能验证业务真在工作 |
| **`exec`** | 进程内独立健康脚本(如 redis-cli ping) | `exec: { command: ["redis-cli", "ping"] }` | 频繁 exec 有性能代价,probe 间隔别太密 |

### Spring Boot Actuator 健康端点推荐

```yaml
# application.yml(业务镜像里配,不在 k8s yaml 里)
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus
      base-path: /actuator
  endpoint:
    health:
      probes:
        enabled: true   # ★ 开启 /actuator/health/liveness 和 /readiness
      show-details: never   # 不要泄漏内部状态
  health:
    db:
      enabled: false  # ★ readiness 别带 DB 检查,DB 抖一下整个 Pod 被摘流
```

### 端点设计原则

- **liveness**:**只检查进程本身**(JVM 没死、事件循环没死)。**不要查 DB / Redis / 下游**,否则 DB 一抖业务 Pod 就被重启,雪崩
- **readiness**:可以查关键依赖(自己的 DB 连接池、必备的下游),但要谨慎 — 一旦失败 Service 摘流,业务流量打到剩下的 Pod
- **startup**:Pod 启动慢(Java / 加载模型)时必加,给业务足够时间初始化,避免被 liveness 误杀

## 各 kind 关键字段速查

### Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: $APP_NAME
  namespace: tmc-v2
spec:
  type: ClusterIP                # 默认 ClusterIP,外暴露走 Ingress;NodePort 慎用(占节点端口)
  selector:
    app: $APP_NAME               # 必须跟 Deployment template labels 一致
  ports:
    - name: http                 # 多端口必填 name
      port: 80                   # Service 端口
      targetPort: $PORT          # 容器端口(或 ports.name 引用)
      protocol: TCP
  sessionAffinity: None          # 有粘性需求改 ClientIP + sessionAffinityConfig
```

### Ingress(用 ingress-nginx)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $APP_NAME
  namespace: tmc-v2
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"      # 上传大文件
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"   # 长接口
    cert-manager.io/cluster-issuer: letsencrypt-prod        # 自动签证
spec:
  ingressClassName: nginx
  tls:
    - hosts: [$DOMAIN]
      secretName: $APP_NAME-tls
  rules:
    - host: $DOMAIN
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: $APP_NAME
                port: { number: 80 }
```

### HPA(v2)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: $APP_NAME
  namespace: tmc-v2
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: $APP_NAME
  minReplicas: 2                 # 至少 2,避免单点
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 70 }
  behavior:                      # ★ 关键,防止抖动
    scaleUp:
      stabilizationWindowSeconds: 0    # 立刻扩
    scaleDown:
      stabilizationWindowSeconds: 300  # 缩容观察 5 分钟,防 burst 后立刻缩
```

### PodDisruptionBudget(配套 HA)

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: $APP_NAME
  namespace: tmc-v2
spec:
  minAvailable: 1                # 或 maxUnavailable: 1;二选一,不能都写
  selector:
    matchLabels:
      app: $APP_NAME
```

### StatefulSet 关键差异

```yaml
spec:
  serviceName: $APP_NAME-headless   # 必须配套 headless service(ClusterIP: None)
  podManagementPolicy: OrderedReady # 或 Parallel(无依赖的可以并行)
  volumeClaimTemplates:             # 自动给每个 Pod 建 PVC
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        storageClassName: <你的 sc>
        resources: { requests: { storage: 20Gi } }
```

### DaemonSet 关键差异

```yaml
spec:
  template:
    spec:
      hostNetwork: true            # 通常需要(网络插件 / 日志采集)
      tolerations:                 # ★ 必加,否则不会调度到 master
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
```

### Job / CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: $JOB_NAME, namespace: tmc-v2 }
spec:
  schedule: "0 2 * * *"            # 北京时间得加 8h 或集群时区配 ETC
  concurrencyPolicy: Forbid        # 上一轮没完不启新轮(避免并发踩踏)
  successfulJobsHistoryLimit: 3    # 历史保留量,默认 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 3              # 失败重试上限
      activeDeadlineSeconds: 3600  # 单 Job 最长 1h,卡住自动 fail
      ttlSecondsAfterFinished: 86400  # 完成后 1 天自动清,不让历史 Pod 堆
      template:
        spec:
          restartPolicy: OnFailure  # Job 必填,Always 不允许
          imagePullSecrets: [{ name: harbor-repository }]
          containers:
            - name: $JOB_NAME
              image: ...
              resources: { requests: ..., limits: ... }   # Job 同样要给
```

### NetworkPolicy(默认 deny 套路)

```yaml
# 1. 默认 deny 所有 ingress
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress, namespace: tmc-v2 }
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
# 2. 白名单放行
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: $APP_NAME-allow, namespace: tmc-v2 }
spec:
  podSelector: { matchLabels: { app: $APP_NAME } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector: { matchLabels: { name: ingress-nginx } }   # 只让 ingress 来
      ports:
        - port: $PORT
```

## 反模式表

| ✗ | ✓ | 为什么 |
|---|---|---|
| `image: $APP_NAME:latest` | `image: $APP_NAME:v1.2.3` 或 `:SNAPSHOT-$BUILD_NUMBER` | latest 没版本约束,回滚没目标 |
| 没 `resources` 段 | requests + limits 都写 | 没 requests 调度不准;没 limits 一个 Pod 吃光节点 |
| 只 `readinessProbe` 不要 `livenessProbe` | 都要 | 假死时永远不重启 |
| 探针用 `tcpSocket` 当首选 | 优先 `httpGet` 接 `/actuator/health/{liveness,readiness}` 或 `/healthz`;没端点才退回 tcpSocket | tcpSocket 只测端口在 listen,业务死循环 / 内存泄漏 / DB 连接池满 完全测不出 |
| `liveness` 用 HTTP `/`(业务主页)探活 | 用专门 `/actuator/health/liveness` 或 `/healthz`(轻量端点) | `/` 可能依赖业务 → 业务慢 / DB 抖就误杀 |
| `liveness` 端点查 DB / 下游 | liveness **只测进程自己**;依赖检查放 readiness | DB 一抖整个 Pod 被重启 → 雪崩 |
| `liveness` 比 `readiness` 严格 | liveness 要**宽松**,readiness 才严格 | 一旦 liveness 失败直接杀 Pod;readiness 失败只是摘流 |
| 无 `imagePullSecrets`,从 Harbor 拉 | `imagePullSecrets: [{ name: harbor-repository }]` | 私有 Harbor 拉不到 |
| `replicas: 1` 还不配 PDB | ≥2 副本 + PodDisruptionBudget | 节点重启时业务断 |
| `hostPath: /var/data` 当业务存储 | PVC + StorageClass | 节点漂移数据丢 |
| Secret 明文 commit yaml | Sealed Secrets / External Secrets / SOPS | git 里出现密码 |
| `kubectl apply -f x.yaml`(不带 namespace) | yaml 里明确 `namespace: xxx` 或 `kubectl apply -n` | 装到错的 ns |
| ConfigMap 改了不 rollout | `kubectl rollout restart deploy/$APP` | Pod 启动时挂载的 cm 不会自动重读 |
| `kubectl create namespace x` | `kubectl create ns x --dry-run=client -o yaml \| kubectl apply -f -` | 后者幂等 |
| DaemonSet 漏 master toleration | 加上 `node-role.kubernetes.io/{master,control-plane}` toleration | DaemonSet 不会调度到 master |
| Job 没 `ttlSecondsAfterFinished` | 设个 86400(1 天) | 历史 Pod 堆积,污染 `kubectl get pods` |

## 多集群版本的注意

`devops/` 下同一个业务有 8 个集群版本(`saas / sd / test / tsl / tzj / whrr / ztwx / huawei-saas / gstest`)。**改一个不要默认套到所有**:

1. 先问用户:**改哪个集群**?(saas?sd?全部?)
2. 改之前 `diff` 一下,看现存差异(往往不一样):
   ```bash
   diff devops/java/host-cluster/saas/pod-saas.yaml \
        devops/java/host-cluster/sd/pod-sd.yaml
   ```
3. 顶部注释里的 `last-updated` 改成今天
4. ≥3 个集群一起改,先列清单给用户确认(见 `linux-ops-edit` skill)

## 镜像地址写哪个

- **从 Harbor 拉**(业务镜像、第三方代理):`$REGISTRY` 由 Jenkins 注入,通常是 `dockerhub.ihome.sxxpqp.top:8443` 等。yaml 里写 `$REGISTRY` 占位
- **从阿里 ACR 拉**(自己构建并推过的):直接写 `registry.cn-hangzhou.aliyuncs.com/sxxpqp/<name>:<tag>`,国内节点直连快
- **不要**写 `docker.io/library/xxx`、`gcr.io/xxx` 等公网地址 → 见 skill `infra-url-rewrite` 改写规则

## 何时调用此 skill

- 用户说"写 deployment / service / ingress / hpa / cronjob / pdb / networkpolicy"
- 用户说"加副本"、"加 probe"、"加 resources"、"改成生产标准"
- 用户说"给某业务 / 某集群补个 Pod 模板"
- 在 `devops/`、`kubernetes/` 下新增 yaml
- review / 检查老 yaml 是不是生产 ready
