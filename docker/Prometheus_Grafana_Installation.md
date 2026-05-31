
# Prometheus + Grafana 安装配置指南

## 一、准备工作

- 确保虚拟机已安装 Docker-CE，并且端口 9090 和 3000 未被占用。
- 防火墙开放端口：
  
  ```bash
  firewall-cmd --zone=public --add-port=9090/tcp --permanent
  firewall-cmd --zone=public --add-port=3000/tcp --permanent
  firewall-cmd --reload
  ```

## 二、Prometheus 安装配置

1. **创建本地持久化目录**：

   ```bash
   mkdir -p /export0/prometheus/data /export0/prometheus/config /export0/prometheus/rules
   ```

2. **编辑采集器规则**

   在 `/export0/prometheus/config` 目录下编辑 `prometheus.yml`：

   ```bash
   vim /export0/prometheus/config/prometheus.yml
   ```

   文件内容如下：

   ```yaml
   global:
     scrape_interval: 45s
     evaluation_interval: 45s

   rule_files:
     - /prometheus/rules/*.rules

   scrape_configs:
     - job_name: 'prometheus'
       static_configs:
         - targets: ['localhost:9090']
   
     - job_name: "static-mysql"
       static_configs:
         - targets: ["172.17.216.19:9104"]

     - job_name: "static-redis"
       static_configs:
         - targets: ["172.17.216.19:9121"]

     - job_name: "static-nginx"
       static_configs:
         - targets: ["172.17.216.20:9113"]

     - job_name: "linux-node"
       static_configs:
         - targets: ["172.17.216.12:9100", "172.17.216.13:9100"]

     - job_name: "linux-docker-node"
       static_configs:
         - targets: ["172.17.216.23:8080", "172.17.216.24:8080"]
   ```

3. **运行 Prometheus**（端口映射 9090）

   ```bash
   docker run --name prometheus -d        -p 9090:9090        -v /etc/localtime:/etc/localtime:ro        -v /export0/prometheus/data:/prometheus/data        -v /export0/prometheus/config:/prometheus/config        -v /export0/prometheus/rules:/prometheus/rules        prom/prometheus:v2.41.0 --config.file=/prometheus/config/prometheus.yml --web.enable-lifecycle
   ```
   
4. **检查收集器数据指标值**

   选择 `Status -> Targets` 查看。

## 三、Grafana 安装配置

1. **运行 Grafana**（端口映射 3000）

   ```bash
   docker run -d        -p 3000:3000        --dns 114.114.114.114        --name=grafana        -v /etc/localtime:/etc/localtime:ro        -v /export0/grafana/data:/var/lib/grafana        -v /export0/grafana/plugins:/var/lib/grafana/plugins        -v /export0/grafana/config/grafana.ini:/etc/grafana/grafana.ini        -e "GF_SECURITY_ADMIN_PASSWORD=admin1q2w.3e"        -e "GF_INSTALL_PLUGINS=grafana-clock-panel,grafana-simple-json-datasource,grafana-piechart-panel"        grafana/grafana:9.3.2
   ```

## 四、运行采集器

### 1. 容器服务采集器

   ```bash
   docker run -d        --volume=/:/rootfs:ro        --volume=/var/run:/var/run:ro        --volume=/sys:/sys:ro        --volume=/var/lib/docker/:/var/lib/docker:ro        --volume=/dev/disk/:/dev/disk:ro        --publish=8080:8080        --detach=true        --name cadvisor        google/cadvisor:latest
   ```
   