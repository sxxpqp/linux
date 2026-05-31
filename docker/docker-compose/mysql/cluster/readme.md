# 每台先启动 mysql
docker compose up -d mysql

# 这个就是进入mysqlsh了

docker exec -it mysql-mgr mysqlsh --uri root@172.16.150.130:3306

var cluster = dba.createCluster('myMGRCluster');
# var cluster = dba.getCluster();


cluster.addInstance("root@172.16.150.129:3306", {recoveryMethod: "clone"})

cluster.addInstance("root@172.16.150.131:3306", {recoveryMethod: "clone"})

cluster.status()


# 授权root具有% 具有远程访问的权限
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY 'YourRootPassword';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;



# 查看集群状态
SELECT 
    MEMBER_HOST, 
    MEMBER_PORT, 
    MEMBER_STATE, 
    MEMBER_ROLE, 
    MEMBER_VERSION 
FROM performance_schema.replication_group_members;



var cluster = dba.getCluster()

cluster.status()

# 切换数据库主备
cluster.setPrimaryInstance('root@172.16.150.131:3306');




ALTER USER 'root'@'%' IDENTIFIED WITH caching_sha2_password BY 'YourRootPassword';
FLUSH PRIVILEGES;