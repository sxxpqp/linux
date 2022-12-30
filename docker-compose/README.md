## 关于docker-compose的日常总结及分享

### 自动安装

#### 安装docker-compose

```
curl -L https://get.daocloud.io/docker/compose/releases/download/v2.8.0/docker-compose-`uname -s`-`uname -m` > /usr/local/bin/docker-compose
```

```
sudo chmod +x /usr/local/bin/docker-compose
```

```
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
```

