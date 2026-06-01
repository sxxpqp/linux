
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
   mkdir  -p  /export0/prometheus/config
   vim /export0/prometheus/config/prometheus.yml
   ```

   文件内容如下：

   ```yaml
global:
  # 数据采集间隔
  scrape_interval:     45s
  # 告警检测间隔
  evaluation_interval: 45s
# 告警规则
rule_files:
# 这里匹配指定目录下所有的.rules文件
  - /prometheus/rules/*.rules
# 采集配置
scrape_configs:
  # 采集项(prometheus)
  - job_name: 'prometheus'
    static_configs:
      # prometheus自带了对自身的exporter监控程序，所以不需额外安装exporter就可配置采集项
      - targets: ['localhost:9090']
      #基于Myql数据库的采集
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
      - targets: ["172.17.216.12:9100","172.17.216.13:9100"]
  - job_name: "linux-docker-node"
    static_configs:
      - targets: ["172.17.216.23:8080", "172.17.216.24:8080"]
   ```

3. **运行 Prometheus**（端口映射 9090）

   ```bash
   docker run --name prometheus -d   --user root    --restart=always -p 9090:9090        -v /etc/localtime:/etc/localtime:ro        -v /export0/prometheus/data:/prometheus/data        -v /export0/prometheus/config:/prometheus/config        -v /export0/prometheus/rules:/prometheus/rules        prom/prometheus:v2.41.0 --config.file=/prometheus/config/prometheus.yml --web.enable-lifecycle
   ```
   
   热更新
   ```
   curl -X POST http://localhost:9090/-/reload
   ```
4. **检查收集器数据指标值**

   选择 `Status -> Targets` 查看。

## 三、Grafana 安装配置

1. **运行 Grafana**（端口映射 3000）

   ```bash
   docker run -d        -p 3000:3000   --user root  --restart=always   --dns 114.114.114.114        --name=grafana        -v /etc/localtime:/etc/localtime:ro        -v /export0/grafana/data:/var/lib/grafana        -v /export0/grafana/plugins:/var/lib/grafana/plugins        -e "GF_SECURITY_ADMIN_PASSWORD=admin"        -e "GF_INSTALL_PLUGINS=grafana-clock-panel,grafana-simple-json-datasource,grafana-piechart-panel"        grafana/grafana:9.3.2
   ```

## 四、运行采集器

### 1. 容器服务采集器

   ```bash
   docker run -d  --restart=always      --volume=/:/rootfs:ro        --volume=/var/run:/var/run:ro        --volume=/sys:/sys:ro        --volume=/var/lib/docker/:/var/lib/docker:ro        --volume=/dev/disk/:/dev/disk:ro        --publish=8080:8080        --detach=true        --name cadvisor        google/cadvisor:latest
   ```
   开放防火墙端口：
```
  firewall-cmd --zone=public --add-port=8080/tcp --permanent
  firewall-cmd --reload
```
2、监控数据库服务：
1）创建数据库访问用户名、密码
```
CREATE USER 'exporter' @ '%' IDENTIFIED BY 'Mysql1q2w.3e' ;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO ' exporter ' @ '%' IDENTIFIED BY 'Mysql1q2w.3e' ;
```
2) 创建本地配置文件
```
mkdir -p /home/mysqld-exporter
vim /home/mysqld-exporter/.my.cnf
```
内容如下:注 XX.XX.XX.XX IP为数据库访问地址：
```
[client]
user=root
password=root
host=172.16.115.19
port=3306
```
3）运行容器 注：172.24.21.134替换为实际数据库IP地址
```
docker run -d --restart=always --name mysqld-exporter -v /etc/localtime:/etc/localtime:ro \
-v /home/mysqld-exporter/.my.cnf:/etc/.my.cnf \
-p 9104:9104 -e DATA_SOURCE_NAME="root:root@(172.24.21.134:3306)/mysql" \
prom/mysqld-exporter --config.my-cnf=etc/.my.cnf
```
4）防火墙端口9104：
```
  firewall-cmd --zone=public --add-port=9104/tcp --permanent
  firewall-cmd --reload
```
3、运行Linux 服务节点采集器 
```
docker run -d --restart=always -p 9100:9100 --name node-exporter  prom/node-exporter
```
防火墙端口9100：
```
firewall-cmd --zone=public --add-port=9100/tcp --permanent
firewall-cmd --reload
```
4、JVM服务节点采集器
```
docker run -d --restart=always --volume=/:/rootfs:ro \
--volume=/var/run:/var/run:ro --volume=/sys:/sys:ro \
--volume=/var/lib/docker/:/var/lib/docker:ro \
--volume=/dev/disk/:/dev/disk:ro --publish=8081:8080 \
--detach=true --name cadvisor google/cadvisor:latest
```
防火墙端口8080：
firewall-cmd --zone=public --add-port=8080/tcp --permanent
firewall-cmd --reload

5、nginx服务节点采集器
Nginx 需要配置stub_status
```
cat << EOF > /opt/nginx-status.conf
server {
    listen 8081;
    server_name localhost;
    location /stub_status {
        stub_status on;
        access_log off;
    }
}
EOF

```

```
docker run --name  my-nginx --restart=always -d -p 80:80 -p 8081:8081 \
    -v /opt/nginx-status.conf:/etc/nginx/conf.d//nginx.conf:ro \ 
    nginx:latest

```
注：172.24.21.134替换为实际运行IP
```
docker run -p 9113:9113 --restart=always nginx/nginx-prometheus-exporter:1.3.0 --nginx.scrape-uri=http://172.24.21.134:8081/stub_status

```
防火墙端口9113：
```
firewall-cmd --zone=public --add-port=9113/tcp --permanent
firewall-cmd --reload

```

5、redis服务节点采集器
先部署redis
```
mkdir -p /home/redis/config /home/redis/data



```

 注：172.24.21.134替换为实际IP
```
docker run -d --restart=always --name redis-exporter -v /etc/localtime:/etc/localtime:ro \
-p 9121:9121 oliver006/redis_exporter '--redis.addr=redis://172.24.21.134:6379'
```

6、部署node-exporter
```
docker run -d --restart=always -p 9100:9100 --name node-exporter  prom/node-exporter
```

五、选择实际指标生成的模版（图形输出）
1、点击new 选择import
 
2、选择ID
 
４、导入IMPORT

 
或从官网下载模版
https://grafana.com/grafana/dashboards
12633：Linux主机详情
14057 mysql
11835 redis
3662 pram
10619 docker
193 docker
9276 linux
179 docker
11600 docker
12767 nginx
8563 jvm
17271 JVM---最优
13694  JVM
14574 gpu
