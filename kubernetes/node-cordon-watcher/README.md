# node-cordon-watcher

> 🟡 实验中 — 监控 K8s 节点 CPU/内存使用率,超过高水位自动 `cordon`(停止调度新 Pod),降到低水位并持续一段时间后自动 `uncordon`。

**解决什么问题**:集群偶尔某台节点 CPU/内存突然飙高,kube-scheduler 不感知容器资源真实用量(只看 requests),继续往这台机器调度,直到 NodeNotReady 才停。本工具在节点真崩之前主动 cordon,把新 Pod 调度走。

> ⚠️ cordon 只阻止**新** Pod 调度,**不驱逐**已有 Pod。如果要驱逐,见 [descheduler](https://github.com/kubernetes-sigs/descheduler)。

---

## 状态机

```
                超 high(默认 80%)
   Normal ─────────────────────────► OverThreshold(连续 TRIGGER_COUNT 次)
     ▲                                          │
     │                                          ▼  N 次确认后
     │                                    ┌──► Cordoned ◄──┐
     │  CPU 和 MEM 都连续 COOLDOWN_SECONDS 秒  │       │        │
     │  低于 LOW_THRESHOLD(默认 70%)         │       │  仍超阈值
     └─────────────────────────────────────────┘       └────────┘
                    (自动 uncordon)
```

**双阈值迟滞**:80% 上、70% 下,留 10% 缓冲带防止临界点反复触发。

---

## 6 道安全护栏

| 护栏 | 默认 | 作用 |
|---|---|---|
| `EXCLUDE_LABELS` | `node-role.kubernetes.io/control-plane,master` | 跳过 master,不动控制面 |
| annotation `managed=true` | 始终 | 只 uncordon 自己 cordon 过的节点,**不冲掉运维手动 cordon** |
| `DRY_RUN` | `true`(初装) | 只打日志 + 发通知,不实际 patch |
| `MIN_HEALTHY_NODES` | `1` | cordon 后健康 worker < 此值则拒绝 cordon |
| `PER_NODE_COOLDOWN` | `300s` | 同节点两次 cordon 之间至少间隔 5min,防 uncordon 后立刻又 cordon 抖动 |
| LeaderElection | 启用 | 多副本只有 leader 决策,防并发 patch |

---

## 参数(deploy.yaml 里都有默认值)

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `METRIC_SOURCE` | `metrics-api` | `metrics-api`(瞬时,集群里 prometheus-adapter 已就绪) 或 `prometheus`(5min 窗口平均) |
| `PROMETHEUS_URL` | `http://prometheus-k8s.monitoring.svc:9090` | 仅 prometheus 模式生效 |
| `CHECK_INTERVAL` | `30s` | 采样间隔 |
| `HIGH_THRESHOLD` | `80` | 触发 cordon 的百分比 |
| `LOW_THRESHOLD` | `70` | 触发自动 uncordon 的百分比(低于此并持续 cooldown 秒) |
| `TRIGGER_COUNT` | `3` | 连续 N 次超阈值才 cordon(默认 3×30s = 90s 防抖) |
| `COOLDOWN_SECONDS` | `600` | 低于 low 持续 N 秒才 uncordon |
| `PER_NODE_COOLDOWN` | `300` | 同节点 cordon 间隔下限(秒) |
| `MIN_HEALTHY_NODES` | `1` | 健康 worker 保护下限 |
| `EXCLUDE_LABELS` | `node-role.kubernetes.io/control-plane,...` | 跳过这些 label 的节点 |
| `INCLUDE_LABELS` | (空) | 非空则只看带这些 label 的节点(白名单) |
| `DRY_RUN` | `true` | 首次上线建议开,跑稳再关 |
| `NOTIFY` / `WX_WEBHOOK_URL` | `true` / 空 | 企微通知,空 URL 自动跳过 |

---

## 部署

### 1) 构建并推镜像(开发机)

```bash
# 登录阿里云 ACR(用户名 sxxpqp)
docker login registry.cn-hangzhou.aliyuncs.com

# 构建 + 推送
bash build-push.sh                  # 默认 tag=git short sha + latest
bash build-push.sh v0.1.0           # 指定 tag
```

### 2) 部署到集群

```bash
# 推荐:先创建企微 webhook Secret(没有 webhook 可跳过)
kubectl -n monitoring create secret generic node-cordon-watcher-secret \
  --from-literal=wx-webhook-url='https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=YOUR_KEY'

# 部署(默认 DRY_RUN=true)
kubectl apply -f deploy.yaml

# 查看日志,先确认指标采集和决策逻辑符合预期
kubectl -n monitoring logs -l app.kubernetes.io/name=node-cordon-watcher -f
```

### 3) 灰度切真生产

```bash
# 关 dry-run 前先看 24h 日志,有没有误判
kubectl -n monitoring set env deployment/node-cordon-watcher DRY_RUN=false

# 如果是大集群,把 MIN_HEALTHY_NODES 调到 N-1,避免极端情况把集群打废
kubectl -n monitoring set env deployment/node-cordon-watcher MIN_HEALTHY_NODES=5
```

---

## 卸载 / 回滚

```bash
# 1) 停 controller
kubectl scale -n monitoring deploy node-cordon-watcher --replicas=0

# 2) 找出所有由本 controller cordon 的节点,批量恢复
kubectl get node -o json | jq -r \
  '.items[] | select(.metadata.annotations."node-cordon-watcher.sxxpqp.top/managed"=="true") | .metadata.name' \
  | xargs -r -n1 kubectl uncordon

# 3) 彻底删除
kubectl delete -f deploy.yaml
```

---

## 本地测试(kind)

```bash
# 跑单元测试(状态机)
go test ./...

# 端到端:kind 集群 + stress
kind create cluster --config kind-3node.yaml
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
docker build -t node-cordon-watcher:dev .
kind load docker-image node-cordon-watcher:dev
# 改 deploy.yaml 的 image 为 node-cordon-watcher:dev
kubectl apply -f deploy.yaml

# 压一台 node
kubectl run stress --image=polinux/stress --restart=Never -- stress --cpu 4 --timeout 600s
kubectl -n monitoring logs -l app.kubernetes.io/name=node-cordon-watcher -f
```

---

## 指标源对比

| 维度 | `metrics-api` | `prometheus` |
|---|---|---|
| 数据 | NodeMetrics(瞬时,~15s 滚动) | PromQL,默认 5min 窗口 avg |
| 依赖 | 集群有 metrics-server 或 prometheus-adapter(本仓库已有) | Prometheus 可达 |
| 防抖 | 靠 `TRIGGER_COUNT` 多次确认 | PromQL 自带窗口平均 + `TRIGGER_COUNT` |
| 代码路径 | `metricsAPISource` | `promQLSource` |
| 推荐 | 小集群、快速反应 | 大集群、避免毛刺误判 |

---

## 踩坑

| 现象 | 原因 | 修法 |
|---|---|---|
| Pod 起不来,Event:`container has runAsNonRoot and image has non-numeric user (app), cannot verify user is non-root` | kubelet 校验 nonroot 时**只认数字 UID**,不解析镜像里的 `/etc/passwd`(也就是 Dockerfile 里 `USER app` 这种名字)。 | Dockerfile 改成 `USER 65532:65532`(创建用户时 `-u 65532`);同时 deploy.yaml securityContext 加 `runAsUser: 65532 / runAsGroup: 65532`。本仓库已修复。 |
| Pod 调度到某 node 后 calico 报 `route ... already exists for an interface other than 'caliXXXX'` | 之前 Pod 的 veth + 路由没清干净(常见于 kubelet 重启 / 强删 Pod / OOM),新 Pod 想用同一个 IP 但路由指向旧 iface。 | 在出问题的 node 上 `ip route show \| grep <冲突IP>` 找到旧路由,`ip route del <IP> dev <旧iface>` 删掉,kubelet 会自动重试;或者 `systemctl restart kubelet` + 重建 calico-node Pod(`kubectl -n calico-system delete pod calico-node-XXX`)。 |
| `METRIC_SOURCE=prometheus` 下日志反复 `dial tcp <prom-svc-ip>:9090: i/o timeout` | kube-prometheus 默认装的 NetworkPolicy `prometheus-k8s` 只放行 label `app.kubernetes.io/name in (prometheus, prometheus-adapter, grafana)` 入站 9090,本 controller 的 label 不在白名单里。 | deploy.yaml 已自带补丁式 `NetworkPolicy: prometheus-allow-node-cordon-watcher`(多 policy 取并集);如果集群禁用 NetworkPolicy 此条无效但也不报错。验证:`kubectl -n monitoring get netpol`。 |
