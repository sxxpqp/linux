# frp 部署

frp 分为服务端（frps）和客户端（frpc）。  
**新版（v0.52+）** 配置文件已从 INI 改为 **TOML 格式（推荐）**，旧版 INI 仍可用但不再支持新特性。

---

## 服务端 frps

### 1. 配置文件（新版 TOML）

`/etc/frps/frps.toml`

```toml
bindAddr = "0.0.0.0"
bindPort = 7000
kcpBindPort = 7000

vhostHTTPPort = 80
vhostHTTPSPort = 443

auth.method = "token"
auth.token = "zkturing.imwork.net"

webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "Xl123456.."

log.to = "./frps.log"
log.level = "info"
log.maxDays = 3

allowPorts = [
  { start = 2000, end = 3000 },
  { single = 3001 },
  { single = 3003 },
  { start = 4000, end = 50000 }
]

transport.tcpMux = true
```

### 2. 方式一：Docker

```bash
docker run -d --privileged --net=host --name=frps --restart=always \
  -v /etc/frps/frps.toml:/frp/frps.toml \
  stilleshan/frps
```

修改配置后重启：

```bash
vi /etc/frps/frps.toml
docker restart frps
```

删除容器：

```bash
docker stop frps && docker rm frps
```

### 3. 方式二：Docker-Compose

`docker-compose-frps.yml`

```yaml
version: "3"
services:
  frps:
    image: stilleshan/frps
    container_name: frps
    restart: always
    network_mode: host
    privileged: true
    volumes:
      - /etc/frps/frps.toml:/frp/frps.toml
```

```bash
docker-compose -f docker-compose-frps.yml up -d
```

---

## 客户端 frpc

### 1. 配置文件（新版 TOML）

`/etc/frpc/frpc.toml`

```toml
serverAddr = "zkturing.imwork.net"
serverPort = 7000
auth.token = "zkturing.imwork.net"
transport.protocol = "kcp"
# transport.tls.enable = true

[[proxies]]
name = "web1"
type = "http"
localIP = "192.168.1.2"
localPort = 5000
customDomains = ["yourdomain.com"]

[[proxies]]
name = "web2"
type = "https"
localIP = "192.168.1.2"
localPort = 5001
customDomains = ["yourdomain.com"]

[[proxies]]
name = "tcp1"
type = "tcp"
localIP = "192.168.1.2"
localPort = 22
remotePort = 22222
```

### 2. 方式一：Docker

```bash
docker run -d --privileged --net=host --name=frpc --restart=always \
  -v /etc/frpc/frpc.toml:/frp/frpc.toml \
  stilleshan/frpc
```

删除容器：

```bash
docker stop frpc && docker rm frpc
```

一键部署脚本：

```bash
curl https://file.iot.store/frpc | bash
```

### 3. 方式二：Docker-Compose

`docker-compose-frpc.yml`

```yaml
version: "3"
services:
  frpc:
    image: stilleshan/frpc
    container_name: frpc
    restart: always
    network_mode: host
    privileged: true
    volumes:
      - /etc/frpc/frpc.toml:/frp/frpc.toml
```

```bash
docker-compose -f docker-compose-frpc.yml up -d
```

---

## 客户端（Windows）

下载 frp 最新版：https://github.com/fatedier/frp/releases

