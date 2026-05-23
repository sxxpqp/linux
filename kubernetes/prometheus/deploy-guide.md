# Prometheus 监控栈部署指南

基于 kube-prometheus-stack，集成 Alertmanager、Blackbox Exporter、PrometheusAlert 等组件。

## 部署架构

```text
┌─────────────────────────────────────────────────────┐
│                    监控架构                           │
├─────────────────────────────────────────────────────┤
│                     kube-prometheus-stack            │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │Prometheus│  │Alertmanager│  │    Grafana       │   │
│  │ Operator │  │  :9093    │  │    :3000         │   │
│  └────┬─────┘  └────┬─────┘  └──────────────────┘   │
│       │              │                               │
│  ┌────┴─────┐  ┌────┴─────┐                          │
│  │CRD 发现  │  │  告警路由  │                          │
│  │- Service │  │ → wx-webhook.wx                     │
│  │  Monitor │  │ → PrometheusAlert                   │
│  │- PodMon  │  │ → 企业微信                           │
│  │- Probe   │  └──────────┘                          │
│  │- PromRule│                                         │
│  └──────────┘                                         │
└─────────────────────────────────────────────────────┘
```

## 1. 安装 kube-prometheus-stack

使用 Helm 安装（推荐）：

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

> `serviceMonitorSelectorNilUsesHelmValues=false` — 允许自动发现所有 ServiceMonitor/PodMonitor/Probe CRD，不限于 Helm 标签。

也可以使用 [values.yaml](values.yaml)（如果已定制），通过 `-f values.yaml` 安装。

## 2. 配置 Alertmanager

### 2.1 修改 Alertmanager 配置

kube-prometheus-stack 默认创建名为 `alertmanager-main` 的 Secret 存储配置。

**方式一：直接修改 Secret**

```bash
kubectl -n monitoring edit secret alertmanager-main
```

`data.alertmanager.yaml` 为 base64 编码的配置。

**方式二：通过 Prometheus Operator 自动生成的 `alertmanager-main` 配置**

部署 [alertmanager-config.yaml](alertmanager-config.yaml)（Alertmanager 实例定义）：

```bash
kubectl apply -f alertmanager-config.yaml
```

### 2.2 告警路由规则

Alertmanager 路由配置（[alert.md](alert.md)）核心逻辑：

| 规则 | 说明 |
|---|---|
| `group_by: [instance, namespace]` | 按实例+命名空间分组 |
| `group_wait: 30s` | 首条告警等待 |
| `group_interval: 5m` | 组内新告警间隔 |
| `repeat_interval: 1h` | 重复告警间隔 |
| `receiver: web.hook.prometheusalert` | 默认发送到 PrometheusAlert |
| `Watchdog` | Watchdog 告警独立处理 |
| `severity=critical` | critical 级别发到 PrometheusAlert |

部署方式：

```bash
# Alertmanager 配置通过 kubectl edit secret alertmanager-main 编辑
# 参考 alert.md 中的配置内容
```

### 2.3 AlertmanagerConfig CRD（Operator 方式）

如果使用 Prometheus Operator 的高级功能，可部署 [alertmanager-config.yaml](alertmanager-config.yaml)：

```bash
kubectl apply -f alertmanager-config.yaml
```

这会在 Alertmanager 中创建独立的告警路由，仅匹配 `severity=critical` 的告警发送 Webhook。

## 3. 采集控制面组件指标

kube-controller-manager 和 kube-scheduler 的 metrics 端口默认绑定在 `127.0.0.1`，需要在配置中改为 `0.0.0.0` 才能被 Prometheus 采集。

### 3.1 kube-controller-manager / scheduler（[kube-system-Service.yaml](kube-system-Service.yaml)）

```yaml
apiVersion: v1
kind: Service
metadata:
  name: kube-controller-manager
  namespace: kube-system
spec:
  selector:
    component: kube-controller-manager
  ports:
    - port: 10257
      targetPort: 10257
      name: https-metrics
---
apiVersion: v1
kind: Service
metadata:
  name: kube-scheduler
  namespace: kube-system
spec:
  selector:
    component: kube-scheduler
  ports:
    - port: 10259
      targetPort: 10259
      name: https-metrics
```

部署：

```bash
kubectl apply -f kube-system-Service.yaml
```

> **注意**：如果 kube-controller-manager / scheduler 以 Pod 方式运行，上述 Service 可以直接通过 selector 匹配。如果是二进制部署且未暴露 metrics，需要先修改启动参数，加上 `--bind-address=0.0.0.0`。

### 3.2 etcd 监控（[extenalservice.yaml](extenalservice.yaml)）

etcd metrics 默认端口为 `2381`（需在 etcd 启动参数中加 `--listen-metrics-urls=http://0.0.0.0:2381`）。

```yaml
# 创建 Headless Service 指向 etcd 节点
apiVersion: v1
kind: Service
metadata:
  name: etcd-k8s
  namespace: kube-system
spec:
  type: ClusterIP
  clusterIP: None
  ports:
    - name: port
      port: 2381
---
# 手动指定 etcd 节点 IP
apiVersion: v1
kind: Endpoints
metadata:
  name: etcd-k8s
  namespace: kube-system
subsets:
  - addresses:
      - ip: 192.168.31.75    # @update 改为实际 etcd 节点 IP
        nodeName: etc-master  # @update 改为节点名
    ports:
      - name: port
        port: 2381
---
# ServiceMonitor 自动发现
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: etcd-k8s
  namespace: monitoring
spec:
  jobLabel: k8s-app
  endpoints:
    - port: port
      interval: 15s
  selector:
    matchLabels:
      k8s-app: etcd
  namespaceSelector:
    matchNames:
      - kube-system
```

> 多 etcd 节点时，在 `Endpoints.subsets.addresses` 下追加：

```yaml
subsets:
  - addresses:
      - ip: 192.168.31.75
        nodeName: etc-1
      - ip: 192.168.31.76    # 追加
        nodeName: etc-2
      - ip: 192.168.31.77    # 追加
        nodeName: etc-3
    ports:
      - name: port
        port: 2381
```

部署：

```bash
kubectl apply -f extenalservice.yaml
```

### 3.3 Node Exporter（外部节点）

对于不在 K8s 集群内的节点，通过 Endpoints + ServiceMonitor 方式采集：

```bash
kubectl apply -f node-export.yaml
```

> 需要修改 `Endpoints` 中 `ip` 为实际节点 IP。

## 4. 外部黑盒监控（Blackbox Exporter）

部署 [Probe CRD](probe.yaml) 实现对公网服务的外部可访问性监控：

```bash
kubectl apply -f probe.yaml
```

```yaml
# probe.yaml 核心配置
spec:
  targets:
    staticConfig:
      static:
        - https://example.com
        - https://baidu.com
  module: http_2xx
  prober:
    url: blackbox-exporter.monitoring.svc:19115
```

前提：集群中已安装 `prometheus-community/prometheus-blackbox-exporter`。

```bash
helm upgrade --install blackbox prometheus-community/prometheus-blackbox-exporter \
  --namespace monitoring
```

## 5. 告警通知

### 方案一：PrometheusAlert 聚合中心（推荐）

[PrometheusAlert](https://github.com/feiyu563/PrometheusAlert) 支持将 Alertmanager 告警推送到钉钉、企业微信、飞书、短信、电话等渠道。

部署：

```bash
kubectl apply -f prometheusalert.yaml
```

包含资源：
- ConfigMap `prometheus-alert-center-conf` — 配置所有通知渠道
- Deployment `prometheus-alert-center` — 服务实例
- Service `prometheus-alert-center:8080` — 对内服务

**配置说明**（`prometheusalert.yaml` 中 ConfigMap）：

| 参数 | 说明 |
|---|---|
| `open-weixin=1` | 开启企业微信通知 |
| `open-dingding=1` | 开启钉钉通知 |
| `wxurl` | 企业微信机器人 Webhook |
| `ddurl` | 钉钉机器人 Webhook |
| `login_user/password` | Web 登录凭证 |

**Alertmanager 中配置路由到 PrometheusAlert**（参考 [alert.md](alert.md)）：

```yaml
receivers:
- name: 'web.hook.prometheusalert'
  webhook_configs:
  - url: 'http://prometheus-alert-center:8080/prometheusalert?type=wx&tpl=prometheus-wx'
```

### 方案二：Grafana wx-webhook（Grafana 告警专用）

Go 编写的轻量 Webhook，将 Grafana 告警转换为企业微信模板卡片消息。

构建镜像：

```bash
cd grafana-wx-webhook
docker build -t registry/grafana-wx-webhook:latest -f wx-webhook-Dockerfile .
docker push registry/grafana-wx-webhook:latest
```

部署：

```bash
kubectl apply -f grafana-wx-webhook/deploy.yaml
```

环境变量：

| 变量 | 说明 |
|---|---|
| `WX_WEBHOOK_URL` | 企业微信机器人 URL |
| `GRAFANA_URL` | Grafana 外部访问地址（用于跳转链接） |
| `ENV_NAME` | 环境标识（生产/预发/测试） |

Grafana 中配置告警通知通道指向 `http://wx-webhook.monitoring:5001`。

### 企业微信告警模板

[prometheus-alert-config.md](prometheus-alert-config.md) 是 PrometheusAlert 的企业微信通知模板，支持：
- 告警/恢复状态识别
- 告警级别、时间、主机信息
- 恢复通知和告警通知分别展示

## 6. 应用监控示例：Nacos

以 Nacos 为例展示完整应用监控配置：

### 6.1 部署 Nacos

```bash
kubectl apply -f nacos.yaml
```

### 6.2 配置指标采集

```bash
# PodMonitor（基于 Pod 标签发现）
kubectl apply -f podmonitor.yaml

# ServiceMonitor（基于 Service 标签发现）
kubectl apply -f servicemointor.yaml
```

### 6.3 配置告警规则

```bash
kubectl apply -f prometheusrule.yaml
```

包含告警规则：
- **NacosServiceDown** — Nacos 实例宕机（`up == 0` 持续 5m）
- **NacosConfigGetErrorRateHigh** — 配置获取错误率 >10%（持续 10m）

## 7. 验证

```bash
# 查看所有组件
kubectl -n monitoring get pods

# 查看 ServiceMonitor
kubectl -n monitoring get servicemonitor

# 查看告警规则
kubectl -n monitoring get prometheusrule

# 查看 Probe
kubectl -n monitoring get probe

# 访问 Prometheus
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090

# 访问 Alertmanager
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093

# 访问 Grafana
kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80
```

## 8. 文件索引

### 核心配置

| 文件 | 说明 |
|---|---|
| [alert.md](alert.md) | Alertmanager 告警路由配置（分组、压制、接收器） |
| [alertmanager-config.yaml](alertmanager-config.yaml) | Alertmanager 实例配置（CRD） |
| [alertmanager-config.md](alertmanager-config.md) | AlertmanagerConfig CRD（Operator 额外路由） |

### 指标采集

| 文件 | 说明 |
|---|---|
| [kube-system-service.yaml](kube-system-service.yaml) | kube-controller-manager / scheduler Service + Endpoints |
| [kube-system-service.yaml](kube-system-service.yaml) | etcd Service + Endpoints + ServiceMonitor |
| [node-export.yaml](node-export.yaml) | 外部节点指标的 Endpoints + ServiceMonitor |
| [extenalservice.yaml](extenalservice.yaml) | 外部服务 Service 示例 |

### 黑盒监控

| 文件 | 说明 |
|---|---|
| [probe.yaml](probe.yaml) | Blackbox Exporter Probe CRD（HTTP 外部探测） |

### 告警通知

| 文件 | 说明 |
|---|---|
| [prometheusalert.yaml](prometheusalert.yaml) | PrometheusAlert 聚合中心（Deployment + ConfigMap + Service） |
| [prometheus-alert-config.md](prometheus-alert-config.md) | 企业微信告警模板 + 测试数据 |
| [grafana-wx-webhook/](grafana-wx-webhook/) | Grafana → 企业微信 Webhook 服务（Go 源码 + Dockerfile + deploy） |
| [prometheusrule.yaml](prometheusrule.yaml) | Prometheus 告警规则（Nacos 示例） |

### 应用监控示例

| 文件 | 说明 |
|---|---|
| [nacos.yaml](nacos.yaml) | Nacos 应用 Deployment + Service |
| [podmonitor.yaml](podmonitor.yaml) | PodMonitor 指标采集（Pod 标签发现） |
| [servicemointor.yaml](servicemointor.yaml) | ServiceMonitor 指标采集（Service 标签发现） |

### 其他

| 文件 | 说明 |
|---|---|
| [alert.md](alert.md) | 含 base64 编码的完整 Alertmanager 配置参考 |
