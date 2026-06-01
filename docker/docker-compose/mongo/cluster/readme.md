# 创建数据目录
mkdir -p /data/mongodb/{config,shard1,shard2,key}

# 生成 keyfile (确保三台机器内容完全一致)
# 如果是第一台机器生成，请将生成的 mongo.key 复制到另外两台
openssl rand -base64 756 > /data/mongodb/key/mongo.key
chmod 400 /data/mongodb/key/mongo.key
chown 999:999 /data/mongodb/key/mongo.key
# 临时关闭防火墙测试
systemctl stop ufw
# 或者显式允许端口
ufw allow 27018/tcp
ufw allow 27019/tcp
ufw allow 27017/tcp

export NODE1_IP=172.16.150.129
export NODE2_IP=172.16.150.130
export NODE3_IP=172.16.150.131


# 1. 初始化 Config Server (在 Node1 执行)
docker exec -it mongo-config mongosh --port 27019 --eval "rs.initiate({_id:'configReplSet',configsvr:true,members:[{_id:0,host:'${NODE1_IP}:27019'},{_id:1,host:'${NODE2_IP}:27019'},{_id:2,host:'${NODE3_IP}:27019'}]})"

# 2. 初始化 Shard1
docker exec -it mongo-shard1 mongosh --port 27018 --eval "rs.initiate({_id:'shard1RS',members:[{_id:0,host:'${NODE1_IP}:27018'},{_id:1,host:'${NODE2_IP}:27018'},{_id:2,host:'${NODE3_IP}:27018'}]})"

# 3. 初始化 Shard2
docker exec -it mongo-shard2 mongosh --port 27011 --eval "rs.initiate({_id:'shard2RS',members:[{_id:0,host:'${NODE1_IP}:27011'},{_id:1,host:'${NODE2_IP}:27011'},{_id:2,host:'${NODE3_IP}:27011'}]})"

# 4. 最后在 Mongos 中添加分片 (可能需要等几秒副本集选举完成)
docker exec -it mongo-mongos mongosh --port 27017 --eval "sh.addShard('shard1RS/${NODE1_IP}:27018'); sh.addShard('shard2RS/${NODE1_IP}:27011')"



docker exec -it mongo-mongos mongosh --port 27017


use admin

db.createUser({
  user: "root",
  pwd: "YourStrongPassword", 
  roles: [ { role: "root", db: "admin" } ]
})
exit


docker exec -it mongo-mongos mongosh --port 27017 -u root -p YourStrongPassword --authenticationDatabase admin --eval "sh.status()"


# 接的修改地址 后面可以不操作
docker exec -it mongo-mongos mongosh --port 27017 --eval "sh.addShard('shard1RS/172.16.150.129:27018'); sh.addShard('shard2RS/172.16.150.129:27011')"

#rm -rf /data/mongodb/config/* /data/mongodb/shard1/* /data/mongodb/shard2/*