<!-- 使用docker-compose的方式部署mysql -->
1.创建工作目录
```
mkdir -p /data/mysql
cd /data/mysql
```
2、编写docker-compose.yaml
```
vim docker-compose.yaml
```
```
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
      - ./data:/var/lib/mysql
      - ./conf.d:/etc/mysql/conf.d
      - ./logs:/logs
    networks:
      - mysql
networks:    
  mysql:
    driver: bridge
```
3、编写数据库配置文件。
```
vim conf.d/mysql.cnf
```
```
[mysqld]
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
[client]
default-character-set=utf8mb4
[mysql]
default-character-set=utf8mb4
```
4、启动mysql
```    
docker-compose up -d
```
5、查看mysql容器
```
docker ps
```

