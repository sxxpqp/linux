# MySQL 5.7 docker-compose 部署

> 源: https://github.com/sxxpqp/linux/blob/main/docker/docker-compose/mysql/mysql.md
> 状态: 验证过

单机 MySQL 5.7,数据 / 配置 / 日志全部持久化到宿主机,默认 root 密码 `Iot@123456`。

## 1. 创建工作目录

```bash
mkdir -p /data/mysql
cd /data/mysql
```

## 2. 编写 `docker-compose.yaml`

```bash
vim docker-compose.yaml
```

```yaml
version: '3.1'
services:
  mysql:
    image: mysql:5.7
    container_name: mysql
    restart: always
    ports:
      - 3306:3306
    environment:
      MYSQL_ROOT_PASSWORD: Iot@123456
    volumes:
      - ./data:/var/lib/mysql       # 数据
      - ./conf.d:/etc/mysql/conf.d  # 自定义配置
      - ./logs:/logs                # 日志
    networks:
      - mysql
networks:
  mysql:
    driver: bridge
```

## 3. 写数据库配置(utf8mb4)

```bash
vim conf.d/mysql.cnf
```

```ini
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci

[client]
default-character-set=utf8mb4

[mysql]
default-character-set=utf8mb4
```

## 4. 启动

```bash
docker-compose up -d
```

## 5. 查看容器

```bash
docker ps
```
