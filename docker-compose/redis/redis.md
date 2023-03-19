#使用docker-compose的方式部署redis
1.创建工作目录
```bash
mkdir -p /data/redis
cd /data/redis
```
2、编写docker-compose.yaml
```bash
vim docker-compose.yaml
```
```yaml
version: '3.1'
services:
  redis:
    image: redis:5.0.5
    container_name: redis
    restart: always
    ports:
      - 6379:6379
    volumes:
      - ./data:/data
      - ./conf/redis.conf:/usr/local/etc/redis/redis.conf
    networks:
      - redis
networks:
    redis:
        driver: bridge
```
3、编写redis配置文件。
```bash
vim conf/redis.conf
```
```bash
bind 0.0.0.0
protected-mode yes
# requirepass Iot@123456
save 900 1
save 300 10
save 60 10000
dir /data
dbfilename dump.rdb
#appendonly yes
#appendfilename "appendonly.aof"
#日志级别
#loglevel debug
daemonize no
#appendfsync everysec
```