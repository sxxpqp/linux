https://dev.mysql.com/downloads/shell/ 

// 先确保清理了旧元数据
// dba.dropMetadataSchema() 
mysqlsh
/js
dba.checkInstanceConfiguration('root@172.16.150.129:3306')
dba.checkInstanceConfiguration('root@172.16.150.130:3306')
dba.checkInstanceConfiguration('root@172.16.150.131:3306')
shell.connect('root@172.16.150.129:3306')
// 直接创建，不带冲突的端口参数
var cluster = dba.createCluster('myCluster')

cluster.addInstance('root@172.16.150.130:3306', {recoveryMethod: 'clone'})
cluster.addInstance('root@172.16.150.131:3306', {recoveryMethod: 'clone'})
cluster.status()