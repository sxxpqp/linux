## 关于docker-compose的日常总结及分享

### 自动安装

#### 安装docker-compose

```
curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
```

```
sudo chmod +x /usr/local/bin/docker-compose
```

```
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
```
#### 安装traefik

```
version: "3.3"

services:

  traefik:
    image: "traefik:v2.10"
    container_name: "traefik"
    command:
      - "--log.level=DEBUG"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.myresolver.acme.tlschallenge=true"
      - "--certificatesresolvers.myresolver.acme.email=sxxxxxx@gmail.com" #修改为自己的邮箱 
      - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
      - "--tracing.jaeger=true"
      - "--tracing.jaeger.localagenthostport=jaeger-collector:6831"
    ports:
      - "80:80"
      - "443:443"
      - "18080:8080"
    restart: always  
    volumes:
      - "./letsencrypt:/letsencrypt"
      - "/var/run/docker.sock:/var/run/docker.sock:ro"
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.rule=Host(`traefik.sxxpqp.top`)" #修改为自己的域名 域名需要解析到服务器公网ip
      - "traefik.http.routers.traefik.entrypoints=websecure"
      - "traefik.http.routers.traefik.tls.certresolver=myresolver"
      - "traefik.http.routers.jtraefik.tls=true"
      - "traefik.http.routers.traefik.service=traefik"
      - "traefik.http.services.traefik.loadbalancer.server.port=8080"
         # 默认请求转发 https 端口
      - "traefik.http.routers.traefik-default.middlewares=redirect-to-https"
      - "traefik.http.routers.traefik-default.rule=Host(`traefik.sxxpqp.top`)" #修改为自己的域名 域名需要解析到服务器公网ip
      - "traefik.http.routers.traefik-default.entrypoints=web"
      - "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"  
```
```
docker-compose up -d
```

通过浏览器访问 https://traefik.sxxpqp.top 即可， 后续服务都可以通过traefik到路由到对应的服务上。下面portainer的安装就是一个例子。


#### 安装portainer

```
version: "3"
services:
  portainer:
    image: portainer/portainer-ce:latest
    ports:
      - 9443:9443
      - 19000:9000
    volumes:
      - portainer_data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    restart: always
    labels: # 配合traefik使用
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(`portainer.sxxpqp.top`)" #修改为自己的域名 域名需要解析到服务器公网ip
      - "traefik.http.routers.portainer.entrypoints=websecure"
      - "traefik.http.routers.portainer.tls.certresolver=myresolver"
      - "traefik.http.routers.portainer.tls=true" 
      - "traefik.http.services.portainer.loadbalancer.server.port=9000" 
      - "traefik.http.routers.portainer-default.middlewares=redirect-to-https"
      - "traefik.http.routers.portainer-default.rule=Host(`portainer.sxxpqp.top`)" #修改为自己的域名 域名需要解析到服务器公网ip
      - "traefik.http.routers.portainer-default.entrypoints=web"
      - "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
    networks:
      - traefik_default
volumes:
  portainer_data:
networks:
  traefik_default:
    external: true
```
```
docker-compose up -d
```
直接通过浏览器访问 https://portainer.sxxpqp.top 即可访问到portainer的web管理界面。
