# VM 监控 — Prometheus 对接方案

纯物理机 / 虚拟机场景下，对接 Prometheus 实现全面监控。

## 目录

- [1. 架构总览](#1-架构总览)
- [2. node_exporter 部署](#2-node_exporter-部署)
- [3. Prometheus 服务发现](#3-prometheus-服务发现)
- [4. 常用告警规则](#4-常用告警规则)
- [5. 系统关键指标](#5-系统关键指标)
- [6. 扩展：blackbox_exporter（网络探测）](#6-扩展blackbox_exporter网络探测)
- [7. Grafana 面板推荐](#7-grafana-面板推荐)
- [8. 安全加固](#8-安全加固)

---

## 1. 架构总览

```
┌──────────────────────────────────────────────┐
│            Grafana (展示 + 告警)               │
└──────────────┬───────────────────────────────┘
               │
┌──────────────▼───────────────────────────────┐
│          Prometheus Server                    │
│  (static config / service discovery / relabel)│
└──┬──────────┬──────────┬──────────┬──────────┘
   │          │          │          │
   ▼          ▼          ▼          ▼
┌──────┐ ┌──────┐ ┌──────┐ ┌──────────┐
│ VM 1 │ │ VM 2 │ │ VM N │ │ 网络设备  │
│node  │ │node  │ │node  │ │blackbox  │
│_exp  │ │_exp  │ │_exp  │ │_exporter │
└──────┘ └──────┘ └──────┘ └──────────┘
```

- 每台 VM 运行 **node_exporter**，暴露 `/metrics`
- Prometheus 通过 **static_configs** 或 **file_sd** 拉取
- 可选 **blackbox_exporter** 探测 ICMP/TCP/HTTP

---

## 2. node_exporter 部署

### 2.1 systemd 方式（推荐）

```bash
# 下载最新版
VERSION=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep tag_name | cut -d'"' -f4)
wget https://github.com/prometheus/node_exporter/releases/download/$VERSION/node_exporter-$VERSION.linux-amd64.tar.gz
tar xzf node_exporter-$VERSION.linux-amd64.tar.gz
sudo cp node_exporter-$VERSION.linux-amd64/node_exporter /usr/local/bin/

# 创建用户
sudo useradd -rs /sbin/nologin node_exporter

# systemd service
cat <<'EOF' | sudo tee /etc/systemd/system/node_exporter.service
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=:9100 \
  --path.procfs=/host/proc \
  --path.sysfs=/host/sys \
  --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)
  --collector.systemd \
  --collector.processes \
  --collector.tcpstat \
  --no-collector.arp \
  --no-collector.bcache \
  --no-collector.edac \
  --no-collector.nfs \
  --no-collector.nfsd \
  --no-collector.wifi
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
```

### 2.2 Docker 方式

```yaml
# docker-compose.yml
version: '3'
services:
  node_exporter:
    image: prom/node-exporter:latest
    container_name: node_exporter
    restart: always
    network_mode: host
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--path.rootfs=/rootfs'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/)'
      - '--collector.systemd'
      - '--collector.processes'
      - '--no-collector.wifi'
```

### 2.3 验证

```bash
curl http://localhost:9100/metrics | head -20
# 能看到 node_cpu_seconds_total、node_memory_MemTotal_bytes 等指标
```

---

## 3. Prometheus 服务发现

### 3.1 静态配置（小规模，< 30 台）

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'vm-node'
    static_configs:
      - targets:
          - 192.168.1.10:9100   # VM-1
          - 192.168.1.11:9100   # VM-2
          - 192.168.1.12:9100   # VM-3
        labels:
          group: production
          datacenter: dc-sh
      - targets:
          - 10.0.0.10:9100
          - 10.0.0.11:9100
        labels:
          group: staging
          datacenter: dc-wh
```

### 3.2 file_sd（推荐，中等规模）

```yaml
# prometheus.yml
scrape_configs:
  - job_name: 'vm-node'
    file_sd_configs:
      - files:
          - '/etc/prometheus/targets/vm/*.json'
        refresh_interval: 30s
```

目标文件 `/etc/prometheus/targets/vm/production.json`：

```json
[
  {
    "targets": ["192.168.1.10:9100", "192.168.1.11:9100"],
    "labels": {
      "group": "production",
      "datacenter": "dc-sh"
    }
  }
]
```

配合 CMDB 或 Ansible 自动生成 target 文件：

```bash
# Ansible 示例：生成 vm targets
ansible all -m shell -a "cat /etc/hostname && echo 9100" \
  | awk '{print "  - targets: [\""$0"\"]"}' \
  > /etc/prometheus/targets/vm/all.json
```

### 3.3 consul_sd（大规模 / 动态环境）

在每台 VM 上注册 service：

```bash
curl -X PUT http://consul:8500/v1/agent/service/register \
  -H 'Content-Type: application/json' \
  -d '{
    "ID": "node-exporter-vm-01",
    "Name": "node_exporter",
    "Address": "192.168.1.10",
    "Port": 9100,
    "Tags": ["production", "dc-sh"],
    "Meta": {
      "hostname": "vm-01"
    },
    "Check": {
      "http": "http://192.168.1.10:9100/metrics",
      "Interval": "15s"
    }
  }'
```

Prometheus 端：

```yaml
scrape_configs:
  - job_name: 'vm-node-consul'
    consul_sd_configs:
      - server: 'consul:8500'
        services: ['node_exporter']
    relabel_configs:
      - source_labels: [__meta_consul_tags]
        regex: '.*production.*'
        action: keep
      - source_labels: [__meta_consul_dc]
        target_label: datacenter
```

---

## 4. 常用告警规则

```yaml
# vm-alerts.yml
groups:
  - name: vm-alerts
    rules:
      # --- 节点可用性 ---
      - alert: NodeDown
        expr: up{job="vm-node"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} 已离线"

      # --- CPU ---
      - alert: HighCpuUsage
        expr: (1 - avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100 > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} CPU 使用率 > 90%"

      # --- 内存 ---
      - alert: HighMemoryUsage
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} 内存使用率 > 90%"

      # --- 磁盘 ---
      - alert: DiskUsage
        expr: (1 - (node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"})) * 100 > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} 磁盘使用率 > 85% ({{ $labels.mountpoint }})"

      # --- IO 压力 ---
      - alert: HighDiskIO
        expr: rate(node_disk_io_time_seconds_total[2m]) > 0.9
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} 磁盘 IO 繁忙率 > 90%"

      # --- 网络 ---
      - alert: HighNetworkErrors
        expr: rate(node_network_receive_errors_total[5m]) / rate(node_network_receive_packets_total[5m]) * 100 > 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.instance }} {{ $labels.device }} 接收错误率 > 1%"

      # --- 进程 ---
      - alert: OOMKillDetected
        expr: increase(node_vmstat_oom_kill[1m]) > 0
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.instance }} 发生 OOM Kill"

      # --- 文件系统预测 ---
      - alert: DiskWillFillIn7Days
        expr: predict_linear(node_filesystem_free_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}[7d], 86400 * 7) < 0
        labels:
          severity: info
        annotations:
          summary: "{{ $labels.instance }} 磁盘预计 7 天内写满"
```

---

## 5. 系统关键指标

| 维度 | 关键指标 | 说明 |
|---|---|---|
| CPU | `node_cpu_seconds_total` | CPU 各 mode 时间，用于算使用率 |
| CPU | `node_load1/5/15` | 系统负载，需结合核数看 |
| 内存 | `node_memory_MemTotal_bytes` | 总内存 |
| 内存 | `node_memory_MemAvailable_bytes` | 实际可用内存 |
| 内存 | `node_memory_Swap_*` | Swap 使用情况 |
| 磁盘 | `node_filesystem_size/avail_bytes` | 各分区使用量 |
| 磁盘 | `node_disk_io_time_seconds_total` | IO 繁忙度 |
| 网络 | `node_network_receive/transmit_bytes_total` | 网络吞吐 |
| 网络 | `node_network_receive/transmit_errors_total` | 网络错误 |
| 进程 | `node_procs_running` | 当前运行队列 |
| 进程 | `node_procs_blocked` | 阻塞的进程数 |
| 系统 | `node_boot_time_seconds` | 系统启动时间 |
| 系统 | `node_nf_conntrack_entries` | conntrack 表大小 |

### 常用 PromQL 速查

```promql
# CPU 使用率（排除 idle 和 iowait）
100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 内存使用率
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

# 磁盘使用率
(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

# 磁盘 IO 繁忙率
rate(node_disk_io_time_seconds_total[5m])

# 网络流量 MB/s
rate(node_network_receive_bytes_total{device="eth0"}[5m]) / 1024 / 1024

# 系统负载（按核数归一化）
node_load1 / count without(cpu) (node_cpu_seconds_total{mode="idle"})

# 预测磁盘 7 天后用量
predict_linear(node_filesystem_free_bytes{mountpoint="/"}[7d], 86400*7)

# 所有节点的 up 状态总数
count(up{job="vm-node"} == 1)
```

---

## 6. 扩展：blackbox_exporter（网络探测）

对 VM 的网络层面做主动探测，不只是等 node_exporter 汇报。

### 部署

```bash
docker run -d --name blackbox_exporter \
  --restart always \
  -p 9115:9115 \
  prom/blackbox-exporter:latest
```

### Prometheus 配置

```yaml
scrape_configs:
  # ICMP ping 探测
  - job_name: 'vm-ping'
    metrics_path: /probe
    params:
      module: [icmp]
    static_configs:
      - targets:
          - 192.168.1.10
          - 192.168.1.11
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115  # blackbox_exporter 地址

  # TCP 端口探测
  - job_name: 'vm-tcp-ports'
    metrics_path: /probe
    params:
      module: [tcp_connect]
    static_configs:
      - targets:
          - '192.168.1.10:22'   # SSH
          - '192.168.1.10:443'  # HTTPS
          - '192.168.1.11:3306' # MySQL
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
```

### 告警规则

```yaml
- alert: VMPingLoss
  expr: probe_success{job="vm-ping"} == 0
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "{{ $labels.instance }} ping 不通"

- alert: VMSSHPortDown
  expr: probe_success{job="vm-tcp-ports", instance=~".*:22"} == 0
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "{{ $labels.instance }} SSH 端口不可达"
```

---

## 7. Grafana 面板推荐

| 面板 ID | 名称 | 说明 |
|---|---|---|
| 1860 | Node Exporter Full | 最全面的主机监控面板 |
| 11074 | Node Exporter Server Metrics | 轻量版，聚焦系统核心指标 |
| 16098 | 1 Node Exporter for Prometheus Dashboard | 中文，带磁盘预测 |
| 9276 | Node Exporter & Blackbox Exporter | 联合展示 |

导入命令：

```bash
# 通过 API 导入
curl -X POST "http://admin:password@grafana:3000/api/dashboards/import" \
  -H "Content-Type: application/json" \
  -d '{"dashboard":{"id":null,"uid":null},"overwrite":true,"inputs":[{"name":"DS_PROMETHEUS","type":"datasource","pluginId":"prometheus","value":"Prometheus"}]}'
```

---

## 8. 安全加固

### 8.1 node_exporter 开启鉴权

v0.18.0+ 支持 basic auth：

```bash
# 创建密码哈希
apt install apache2-utils -y
htpasswd -nBC 12 "" | tr -d ':\n'  # 交互式输入密码

cat <<'EOF' > /etc/node_exporter/config.yml
basic_auth_users:
  prometheus: $2y$12$...  # 上面生成的 hash
EOF
```

启动参数加上 `--web.config=/etc/node_exporter/config.yml`

Prometheus 端：

```yaml
scrape_configs:
  - job_name: 'vm-node'
    basic_auth:
      username: prometheus
      password: your-password
    static_configs:
      - targets: ['192.168.1.10:9100']
```

### 8.2 防火墙限制

```bash
# 只允许 Prometheus Server 的 IP 访问 9100
iptables -A INPUT -p tcp --dport 9100 -s 10.0.0.100 -j ACCEPT
iptables -A INPUT -p tcp --dport 9100 -j DROP
```

### 8.3 禁用不必要 collector

```bash
# 只开启需要 collector，减少暴露面
--no-collector.arp
--no-collector.bcache
--no-collector.edac
--no-collector.nfs
--no-collector.nfsd
--no-collector.wifi
```

---

> **提示：** 如果你的 VM 数量超过 100 台，建议上 **VictoriaMetrics** 作为 Prometheus 后端存储，remote write 写过去。相关配置见 `../victoria-metrics/`。
