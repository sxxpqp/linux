### 主配置
```
[mysqld]
character_set_server=utf8
collation-server=utf8_general_ci
lower_case_table_names =1
max_connections = 800
max_connect_errors = 1000
max_allowed_packet= 1073741824
sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION
event_scheduler = 1
# 为服务器分配id，可以自定义，不区分大小，起标识作用。不同数据库节点分配不同的id
server_id=001
# 打开Mysql 日志，日志格式为二进制
log-bin=mysql-bin
# 可选项Mixed,Statement,Row，默认格式是 Statement，mixed混合Satement，ROW两种模式
binlog_format=row
# 日志过期时间
expire_logs_days  = 7
# 下面这两个参数非常重要
# 这个参数一般用在主主同步中，用来错开自增值, 防止键值冲突，master2上面改为2
auto_increment_offset = 1
# 这个参数一般用在主主同步中，用来错开自增值, 防止键值冲突
auto_increment_increment = 2
# 当启用时，服务器通过只允许执行可以使用GTID安全地记录的语句来强制GTID一致性。
enforce-gtid-consistency=true
# 启用基于GTID的复制，启用之前必须保证enforce-gtid-consistency=true
gtid_mode=ON
# 该选项让从库写入哪些来自于主库的更新，并把这些更新写入bin-log文件，一台服务器即做主库又做从库必须开启
log-slave-updates=true
# 只对新的session生效，为了关闭旧的session，需选择一个非业务时间段，重启源数据库并重置任务即可。
binlog_row_image  = full
##为了数据安全再配置
sync_binlog=1
innodb_flush_log_at_trx_commit=1
# 将函数复制到slave
log_bin_trust_function_creators = 1
# 需要复制的数据库名，如果复制多个数据库，重复设置这个选项即可
binlog-do-db = turingcloudx,turingcloudx_ac,turingcloudx_daily,turingcloudx_dataanalysis,turingcloudx_device,turingcloudx_mp,turingcloudx_overview,turingcloudx_pay,turingcloudx_video
# 以表形式保存
master_info_repository=TABLE
relay_log_info_repository=TABLE
relay_log_recovery=ON
```
### 从配置或者主配置
```
[mysqld]
# 主数据库端ID号，全局唯一，通常用IP地址最后一位
server_id = 10
# 开启二进制日志
log-bin = mysql-bin
# 该选项让从库写入哪些来自于主库的更新，并把这些更新写入bin-log文件，一台服务器即做主库又做从库必须开启
log-slave-updates=true
# 控制binlog的写入频率。每执行多少次事务写入一次(这个参数性能消耗很大，但可减小MySQL崩溃造成的损失)
sync_binlog = 1
innodb_flush_log_at_trx_commit=1
# 下面这两个参数非常重要
# 这个参数一般用在主主同步中，用来错开自增值, 防止键值冲突，master2上面改为2
auto_increment_offset = 2
# 这个参数一般用在主主同步中，用来错开自增值, 防止键值冲突
auto_increment_increment = 2
# 二进制日志自动删除的天数，默认值为0,表示“没有自动删除”，启动时和二进制日志循环时可能删除
expire_logs_days = 7
# 当启用时，服务器通过只允许执行可以使用GTID安全地记录的语句来强制GTID一致性。
enforce-gtid-consistency=true
# 启用基于GTID的复制，启用之前必须保证enforce-gtid-consistency=true
gtid_mode=ON
# 将函数复制到slave
log_bin_trust_function_creators = 1

# 以表形式保存
master_info_repository=TABLE
relay_log_info_repository=TABLE
relay_log_recovery=ON
# 只读配置
read_only=1
```

```
create user 'repl'@'%' identified by 'Iot@123456';
grant replication slave on *.* to 'repl'@'%';
flush privileges;
```

```
CHANGE MASTER TO MASTER_HOST = '139.198.123.207', MASTER_USER = 'slave', MASTER_PASSWORD = 'Iot@123456', MASTER_PORT = 33306, MASTER_AUTO_POSITION = 1, MASTER_RETRY_COUNT = 0
```

```
 change master to 
     master_host='192.168.1.221',
     master_port=3306,
     master_user='repl',
     master_password='vo7kphndxlzfr6u3',
 MASTER_AUTO_POSITION=1,
 GET_MASTER_PUBLIC_KEY=1;
```
在两个数据库实例中启动同步


```
start slave;
```
```
show slave status
```


### 主主复制企业级
```
mkdir -p /data/master
cat >docker-compose.yaml<<eof
version: '3'
services:
  mysql:
    restart: always
    image: mysql:5.7.30
    container_name: mysql-master
    volumes:
      - /data/master/mydir:/mydir
      - /data/master/datadir:/var/lib/mysql
      - /data/master/conf/my.cnf:/etc/mysql/my.cnf
      # 数据库还原目录 可将需要还原的sql文件放在这里
      - /data/master/source:/docker-entrypoint-initdb.d
    environment:
      - "MYSQL_ROOT_PASSWORD=Iot@123456"
      - "TZ=Asia/Shanghai"
    ports:
      # 使用宿主机的3306端口映射到容器的3306端口
      # 宿主机：容器
      - 3306:3306
  slave:
    restart: always
    image: mysql:5.7.30
    container_name: mysql-slave
    volumes:
      - /data/slave/mydir:/mydir
      - /data/slave/datadir:/var/lib/mysql
      - /data/slave/conf/my.cnf:/etc/mysql/my.cnf
      # 数据库还原目录 可将需要还原的sql文件放在这里
      - /data/slave/source:/docker-entrypoint-initdb.d
    environment:
      - "MYSQL_ROOT_PASSWORD=Iot@123456"
      - "TZ=Asia/Shanghai"
    ports:
      # 使用宿主机的3306端口映射到容器的3306端口
      # 宿主机：容器
      - 3307:3306
eof      
```
```         
cat>/data/master/conf/my.cnf<<eof
[mysqld]
user=mysql
default-storage-engine=INNODB
character-set-server=utf8
character-set-client-handshake=FALSE
collation-server=utf8_unicode_ci
init_connect='SET NAMES utf8'
server_id = 201                    #这里的ID号与从库上或者主库上的ID必须保证不一样
log-bin=mysql-bin                    #可以自定义 这里定义为 log-bin=/data/log-bin/log-bin-3310
binlog_format=row                    #主从复制模式
log-slave-updates=true                 #slave 更新是否记入日志
gtid-mode=on                                   # 启用gtid类型，否则就是普通的复制架构
enforce-gtid-consistency=true          #强制GTID 的一致性 
master-info-repository=TABLE        #主服信息记录库=表 /文件
relay-log-info-repository=TABLE    #中继日志信息记录库
sync-master-info=1                         #同步主库信息
slave-parallel-workers=10                #从服务器的SQL 线程数，要复制库数目相同
binlog-checksum=CRC32                   # 校验码 ，可以自定义
master-verify-checksum=1               #主服校验
slave-sql-verify-checksum=1             #从服校验
binlog-rows-query-log_events=1     #二进制日志详细记录事件
report-port=3307                             #提供复制报告端口，当前实例端口号
report-host=192.168.1.46                #提供复制报告主机，本机的ip地址
[client]
default-character-set=utf8
[mysql]
default-character-set=utf8
eof

mkdir -p /data/slave
cat>/data/slave/conf/my.cnf<<eof
[mysqld]
user=mysql
default-storage-engine=INNODB
character-set-server=utf8
character-set-client-handshake=FALSE
collation-server=utf8_unicode_ci
init_connect='SET NAMES utf8'
server_id=202                    #这里的ID号与从库上或者主库上的ID必须保证不唯一
log-bin=mysql-bin                    #可以自定义 这里定义为 log-bin=/data/log-bin/log-bin-3310
binlog_format=row                    #主从复制模式
log-slave-updates=true                 #slave 更新是否记入日志
gtid-mode=on                                   # 启用gtid类型，否则就是普通的复制架构
enforce-gtid-consistency=true          #强制GTID 的一致性 
master-info-repository=TABLE        #主服信息记录库=表 /文件
relay-log-info-repository=TABLE    #中继日志信息记录库
sync-master-info=1                         #同步主库信息
slave-parallel-workers=13                 #从服务器的SQL 线程数，要复制库数目相同
binlog-checksum=CRC32                   # 校验码 ，可以自定义
master-verify-checksum=1               #主服校验
slave-sql-verify-checksum=1             #从服校验
binlog-rows-query-log_events=1     #二进制日志详细记录事件
report-port=3306                            #提供复制报告端口，当前实例端口号
report-host=192.168.1.46               #提供复制报告主机，本机的ip地址
replicate-wild-ignore-table=mysql.%
replicate-wild-ignore-table=information_schema.%
replicate-wild-ignore-table=sys.%
replicate-wild-ignore-table=performance_schema.%
replicate-wild-ignore-table=turingcloudx_config.%
replicate-wild-ignore-table=turingcloudx.sys_tenant
replicate-wild-ignore-table=turingcloudx_device.device_message_point_data
[client]
default-character-set=utf8
[mysql]
default-character-set=utf8
eof
```


```
grant replication slave,replication client on *.* to slave@'%'identified by 'Iot@123456';
flush privileges;
```
```
change master to master_host='192.168.1.46',master_port=3306,master_user='slave',master_password='Iot@123456',master_auto_position=1;
slave start;
show slave status;
```
```
mysqldump -hhost -uroot -ppassword --single-transaction --all-databases > `date +%F`backup.sql
```
```
mysqldump -h139.198.123.207 -P33306 -uroot -p --single-transaction --master-data=0 --set-gtid-purged=OFF --hex-blob --triggers --routines --events --all-databases > `date +%F`backup.sql
```
### 不建议设置支持跳过
```
set global slave_exec_mode=IDEMPOTENT;
```
### 通过show slave status 
查看到错误的表的信息，在解决数据一致性问题。
```
select *  from performance_schema.replication_applier_status_by_worker;

```
### 需要同步之前数据库一致
```
FLUSH TABLES WITH READ LOCK ;
UNLOCK TABLES ;
reset MASTER;
```
