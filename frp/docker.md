## frp部署

### 服务端

#### 1.配置文件

**正确配置 frps.ini 文件**

```
vi /etc/frps/frps.ini
```

**配置frps.ini参考**

```
[common]
bind_addr = 0.0.0.0
bind_port = 7000
bind_udp_port = 7001
kcp_bind_port = 7000
vhost_http_port = 80
vhost_https_port = 443
dashboard_addr = 0.0.0.0
dashboard_port = 7500
dashboard_user = admin
dashboard_pwd = Xl123456..
log_file = ./frps.log
log_level = info
log_max_days = 3
disable_log_color = false
token = zkturing.imwork.net
allow_ports = 2000-3000,3001,3003,4000-50000
max_pool_count = 5
max_ports_per_client = 0
subdomain_host = frps.com
tcp_mux = true
```

#### 2.运行服务

执行以下命令启动服务

```
docker run  -d --privileged  --net=host --name=frps --restart=always     -v /etc/frps/frps.ini:/frp/frps.ini     stilleshan/frps
```

删除命令

```
docker stop frps && docker rm frps
```



#### 3.修改配置

**服务运行中修改 frps.ini 配置后需重启 frps 服务**

```
vi /root/frps/frps.ini
# 修改 frps.ini 配置
docker restart frps
# 重启 frps 容器即可生效
```

### 客户端

**window**

```
https://github.com/fatedier/frp/releases #下载window客户端
```

**linux**

#### 1.配置文件

**正确配置 frpc.ini 文件**

```
mkdir /etc/frpc
```

```
vi /etc/frpc/frpc.ini
```

**配置frpc.ini参考**

```
[common]
server_addr = zkturing.imwork.net
server_port = 7000
token = zkturing.imwork.net
protocol = kcp
<!-- tls_enable = true -->

[web1_xxxxx]
type = http
local_ip = 192.168.1.2
local_port = 5000
custom_domains = yourdomain.com

[web2_xxxxx]
type = https
local_ip = 192.168.1.2
local_port = 5001
custom_domains = yourdomain.com

[tcp1_xxxxx]
type = tcp
local_ip = 192.168.1.2
local_port = 22
remote_port = 22222
custom_domains = yourdomain.com
```

#### 2.运行服务

**执行以下命令启动服务**

```
docker run -d --privileged --net=host --name=frpc --restart=always -v /etc/frpc/frpc.ini:/frp/frpc.ini stilleshan/frpc
```

**删除容器**

```
docker stop frpc && docker rm frpc
```

```
docker rm -f frpc
```

**一键部署frpc脚本**

```
curl https://file.iot.store/frpc|bash
```

