# Prometheus 监控栈安装步骤

基于 kube-prometheus-stack，集成 Alertmanager、Blackbox Exporter、PrometheusAlert 等组件。

## 部署架构

```text
┌──────────────────────────────────────────────────────────────┐
│                      监控架构                                 │
├──────────────────────────────────────────────────────────────┤
│                   kube-prometheus-stack                       │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐                   │
│  │Prometheus│  │Alertmanager│  │  Grafana  │                   │
│  │ Operator │  │  :9093    │  │  :3000    │                   │
│  └────┬─────┘  └────┬─────┘  └───────────┘                   │
│       │              │                                        │
│  ┌────┴─────┐  ┌────┴─────────────┐                           │
│  │CRD 发现  │  │  告警路由          │                          │
│  │- Service │  │ → wx-webhook      │                          │
│  │  Monitor │  │ → PrometheusAlert │                          │
│  │- PodMon  │  │ → 企业微信         │                          │
│  │- Probe   │  └──────────────────┘                          │
│  │- PromRule│                                                  │
│  └──────────┘                                                  │
└──────────────────────────────────────────────────────────────┘
```

## 前置条件

- Kubernetes 集群（v1.19+）
- Helm 3 已安装
- kubectl 已配置集群访问权限
- 集群内 control plane 组件 metrics 端口已绑定到 `0.0.0.0`

---

## 1. 安装 kube-prometheus-stack

```bash
# 添加 Helm 仓库
helm repo add prometheus-community https://nexus.ihome.sxxpqp.top:8443/repository/prometheus-community/
helm repo update

# 安装
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

| 参数 | 说明 |
|---|---|
| `grafana.adminPassword` | Grafana 管理员密码（生产环境请修改） |
| `serviceMonitorSelectorNilUsesHelmValues=false` | 允许自动发现所有 ServiceMonitor/PodMonitor/Probe，不限于 Helm 标签 |

---

## 2. 配置 Alertmanager 告警路由

### 2.1 部署 Alertmanager 实例 CRD

```bash
kubectl apply -f alertmanager-config.yaml
```

### 2.2 配置告警路由规则

编辑 Alertmanager Secret：

```bash
kubectl -n monitoring edit secret alertmanager-main
```

路由策略参考（详见 [alert.md](alert.md)）：

| 参数 | 值 | 说明 |
|---|---|---|
| `group_by` | `[instance, namespace]` | 按实例+命名空间分组 |
| `group_wait` | `30s` | 首条告警等待时间 |
| `group_interval` | `5m` | 同组新告警间隔 |
| `repeat_interval` | `1h` | 重复告警间隔 |
| 默认接收器 | `web.hook.prometheusalert` | 发送到 PrometheusAlert |

### 2.3 AlertmanagerConfig CRD

```bash
kubectl apply -f alertmanager-config.yaml
```

匹配 `severity=critical` 告警，发送 Webhook 到 PrometheusAlert。

---

## 3. 采集控制面组件指标

### 3.1 kube-controller-manager / kube-scheduler

**前置条件**：修改启动参数将 metrics 绑定到 `0.0.0.0`。

```bash
kubectl apply -f kube-system-controller-manager-Service.yaml
```

> 该文件为 kube-controller-manager（port 10257）和 kube-scheduler（port 10259）创建 Service，供 ServiceMonitor 自动发现。

### 3.2 etcd 监控

**前置条件**：etcd 启动参数添加 `--listen-metrics-urls=http://0.0.0.0:2381`。

```bash
kubectl apply -f extenalservice.yaml
```

配置组成：Headless Service（`etcd-k8s`）+ Endpoints（指定 etcd 节点 IP）+ ServiceMonitor。

> 部署前修改 `Endpoints.subsets.addresses` 中的 IP 和 nodeName 为实际 etcd 节点信息。

### 3.3 外部节点 Node Exporter

```bash
kubectl apply -f node-export.yaml
```

> 部署前修改 `Endpoints` 中 IP 为实际外部节点 IP。

---

## 4. 外部黑盒监控（Blackbox Exporter）

### 4.1 安装 Blackbox Exporter

```bash
helm upgrade --install blackbox prometheus-community/prometheus-blackbox-exporter \
  --namespace monitoring
```

### 4.2 部署 Probe CRD

```bash
kubectl apply -f probe.yaml
```

对公网服务做 HTTP 2XX 外部可访问性探测（如 `https://example.com`、`https://baidu.com`）。

---

## 5. 部署告警通知

### 方案一：PrometheusAlert 聚合中心（推荐）

```bash
kubectl apply -f prometheusalert.yaml
```

部署资源：ConfigMap（渠道配置）+ Deployment + Service（8080）。

Alertmanager 中配置路由到 PrometheusAlert：

```yaml
receivers:
- name: 'web.hook.prometheusalert'
  webhook_configs:
  - url: 'http://prometheus-alert-center:8080/prometheusalert?type=wx&tpl=prometheus-wx'
```

### 方案二：Grafana 企业微信 Webhook

```bash
cd grafana-wx-webhook
docker build -t registry/grafana-wx-webhook:latest -f wx-webhook-Dockerfile .
docker push registry/grafana-wx-webhook:latest
kubectl apply -f grafana-wx-webhook/deploy.yaml
```

Grafana 中配置告警通知通道指向 `http://wx-webhook.monitoring:5001`。

---

## 6. 应用监控（以 Nacos 为例）

```bash
# 6.1 部署 Nacos
kubectl apply -f nacos.yaml

# 6.2 配置指标采集（二选一或同时使用）
kubectl apply -f podmonitor.yaml      # PodMonitor：基于 Pod 标签发现
kubectl apply -f servicemointor.yaml  # ServiceMonitor：基于 Service 标签发现

# 6.3 配置告警规则
kubectl apply -f prometheusrule.yaml
```

告警规则：
- **NacosServiceDown** — `up == 0` 持续 5m（critical）
- **NacosConfigGetErrorRateHigh** — 配置获取错误率 >10% 持续 10m（warning）

---

## 7. 验证

```bash
# 查看所有 Pod
kubectl -n monitoring get pods

# 查看 ServiceMonitor
kubectl -n monitoring get servicemonitor

# 查看 PodMonitor
kubectl -n monitoring get podmonitor

# 查看 PrometheusRule
kubectl -n monitoring get prometheusrule

# 查看 Probe
kubectl -n monitoring get probe

# 端口转发
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093
kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80
```

访问地址：
- Prometheus: `http://localhost:9090`
- Alertmanager: `http://localhost:9093`
- Grafana: `http://localhost:3000`（用户名 `admin`）

---

## 8. 文件索引

| 文件 | 用途 |
|---|---|
| [alertmanager-config.yaml](alertmanager-config.yaml) | Alertmanager 实例 CRD |
| [alertmanager-config.md](alertmanager-config.md) | AlertmanagerConfig CRD 配置说明 |
| [alert.md](alert.md) | Alertmanager 路由策略 |
| [prometheusrule.yaml](prometheusrule.yaml) | 告警规则（Nacos 示例） |
| [kube-system-controller-manager-Service.yaml](kube-system-controller-manager-Service.yaml) | kube-controller-manager / scheduler Service |
| [extenalservice.yaml](extenalservice.yaml) | etcd Service + Endpoints + ServiceMonitor |
| [node-export.yaml](node-export.yaml) | 外部节点 Node Exporter 采集 |
| [probe.yaml](probe.yaml) | Blackbox 外部探测 Probe CRD |
| [prometheusalert.yaml](prometheusalert.yaml) | PrometheusAlert 聚合中心 |
| [prometheus-alert-config.md](prometheus-alert-config.md) | 企业微信告警模板 |
| [servicemointor.yaml](servicemointor.yaml) | ServiceMonitor（Nacos） |
| [podmonitor.yaml](podmonitor.yaml) | PodMonitor（Nacos） |
| [nacos.yaml](nacos.yaml) | Nacos 应用部署 |
| [grafana-wx-webhook/](grafana-wx-webhook/) | Grafana → 企业微信 Webhook 服务 |
