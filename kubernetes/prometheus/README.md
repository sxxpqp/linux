# Prometheus 监控

基于 **kube-prometheus**（原始 manifests，非 helm chart）的 K8s 监控栈，包含 Prometheus Operator CRD、Alertmanager、PrometheusAlert 告警中心、Grafana 企业微信 Webhook。

## 一键脚本

| 脚本 | 用途 |
|---|---|
| [install.sh](install.sh) | 一键安装（`--skip-crd` 跳过 CRD，`--dry-run` 预演） |
| [uninstall.sh](uninstall.sh) | 一键卸载（`--crd` 同时删 CRD，`--purge` 完整清理） |

```bash
bash install.sh             # 标准安装
bash install.sh --skip-crd  # CRD 已存在时复跑

bash uninstall.sh           # 保留 CRD + PVC（不影响业务 ServiceMonitor）
bash uninstall.sh --crd     # 同时删 CRD（业务 monitor 都会消失）
bash uninstall.sh --purge   # 完全清理（CRD + PVC + 可选删 namespace）
```

> **install 关键点**：CRD 用 `kubectl apply --server-side` 避免 last-applied annotation 256KB 上限。如果遇到 "unknown field spec.otlp" 这类错误，说明集群 CRD 老于 v0.78，必须先跑 install.sh 或单独 apply `manifests/setup/` 升级 CRD。

## 文件说明

### 部署文档

| 文件 | 说明 |
|---|---|
| [install-steps.md](install-steps.md) | 完整部署文档（顶部已注明 §1 helm 章节废弃，使用 install.sh；后面 Alertmanager / kube-system 组件 / etcd / Blackbox 配置仍有效） |

### 核心 CRD 配置

| 文件 | 说明 |
|---|---|
| [alertmanager-config.yaml](alertmanager-config.yaml) | Alertmanager 实例定义：monitoring.coreos.com/v1，3 副本部署，关联 configSecret，匹配 AlertmanagerConfig 标签 |
| [alertmanager-config.md](alertmanager-config.md) | AlertmanagerConfig CRD：monitoring.coreos.com/v1alpha1，critical 级别告警 Webhook 发送，groupBy/groupWait/groupInterval 路由配置 |

### 告警规则

| 文件 | 说明 |
|---|---|
| [prometheusrule.yaml](prometheusrule.yaml) | PrometheusRule 示例（Nacos）：NacosServiceDown（up==0 持续 5m critical）、NacosConfigGetErrorRateHigh（配置获取错误率>10% 持续 10m warning） |

### 指标采集（ServiceMonitor / PodMonitor）

| 文件 | 说明 |
|---|---|
| [kube-system-Service.yaml](kube-system-Service.yaml) | kube-controller-manager（10257）和 kube-scheduler（10259）的 Service，供 Prometheus ServiceMonitor 发现 |
| [extenalservice.yaml](extenalservice.yaml) | etcd 监控：Headless Service（2381）+ Endpoints（指定 etcd 节点 IP）+ ServiceMonitor 三件套 |
| [node-export.yaml](node-export.yaml) | 外部节点 node-exporter 采集：Headless Service（9100）+ Endpoints（指定节点 IP）+ ServiceMonitor |
| [servicemointor.yaml](servicemointor.yaml) | ServiceMonitor 示例（Nacos）：匹配 app=nacos 标签的 Service，采集 /nacos/actuator/prometheus 指标 |
| [podmonitor.yaml](podmonitor.yaml) | PodMonitor 示例（Nacos）：匹配 app=nacos 标签的 Pod，采集 /nacos/actuator/prometheus 指标 |

### 黑盒监控

| 文件 | 说明 |
|---|---|
| [probe.yaml](probe.yaml) | Blackbox Exporter Probe CRD：HTTP 2XX 外部探测，staticConfig 静态目标（https://example.com），关联 blackbox-exporter 服务 |

### 应用部署

| 文件 | 说明 |
|---|---|
| [nacos.yaml](nacos.yaml) | Nacos 服务 Deployment + Service：standalone 模式，8848/9848/9849 端口，NodePort 30849，Prometheus annotations 自动发现注解 |
| [prometheusalert.yaml](prometheusalert.yaml) | PrometheusAlert 告警聚合中心：ConfigMap（app.conf 配置钉钉/企业微信/飞书/短信/电话等渠道）、Deployment、Service 8080，支持多通道告警推送 |

### 告警通知

| 文件 | 说明 |
|---|---|
| [alert.md](alert.md) | Alertmanager 配置参考：group_by/group_interval/repeat_interval 路由策略、inhibit_rules 告警压制、Watchdog/InfoInhibitor 处理、PrometheusAlert Webhook 接收器配置 |
| [prometheus-alert-config.md](prometheus-alert-config.md) | 企业微信告警模板（Go template 格式）：告警/恢复状态识别、级别/时间/主机信息、PrometheusAlert 模板语法、JSON 测试数据 |
| [grafana-wx-webhook/](grafana-wx-webhook/) | Grafana → 企业微信 Webhook 服务：Go 源码（main.go 处理 Alertmanager/Grafana payload，企业微信模板卡片消息）、Dockerfile（多阶段构建，scratch 极简镜像）、K8s 部署配置 |

### 其他

| 文件 | 说明 |
|---|---|
| [extenalservice.yaml](extenalservice.yaml) | 外部服务 Service 定义 |

> 详细部署步骤参考 [install-steps.md](install-steps.md)；一键安装用 [install.sh](install.sh)。

---

## Prometheus standalone（observability 命名空间）

用于接收 Alloy 推来的 RED/拓扑指标（remote_write），与 kube-prometheus-stack 独立部署，互不影响。

### 安装

```bash
helm upgrade prometheus prometheus-community/prometheus \
  -n observability \
  --set server.extraArgs.web\\.enable-remote-write-receiver="" \
  --set alertmanager.enabled=false \
  --set pushgateway.enabled=false

kubectl rollout status deployment prometheus-server -n observability
```

### 验证 remote_write 接收端已开启

```bash
kubectl get pod -n observability -l app.kubernetes.io/name=prometheus \
  -o jsonpath='{.items[0].spec.containers[0].args}' | python3 -m json.tool | grep remote
```

预期输出：`--web.enable-remote-write-receiver`

### Alloy remote_write 地址

```alloy
prometheus.remote_write "default" {
  endpoint {
    url = "http://prometheus-server.observability:9090/api/v1/write"
  }
}
```

| 参数 | 说明 |
|---|---|
| `web.enable-remote-write-receiver` | 开启 Prometheus 接收 remote_write 数据 |
| `alertmanager.enabled=false` | observability 命名空间不需要独立 Alertmanager |
| `pushgateway.enabled=false` | 不需要 Pushgateway |
