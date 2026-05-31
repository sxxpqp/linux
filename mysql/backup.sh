#!/bin/bash
# 1. 环境定义
date_now=$(date "+%Y%m%d_%H%M%S")
backUpFolder="/database/mysql/xianshang-backup"
username="root"
password="YourRootPassword"
host="172.16.0.190"
port="3306"
mysql_image="mysql:8.0"

# 2. 准备目录
mkdir -p "$backUpFolder"

# 3. 核心：排除系统库并执行备份
fileName="business_only_${date_now}.sql.gz"

echo "Starting filtered backup (excluding system schemas)..."

docker run --rm \
  -v "${backUpFolder}:/backup" \
  ${mysql_image} \
   sh -c "
     # 动态获取非系统库列表 (排除 mysql, sys, info, perf 以及集群元数据库)
     db_list=\$(mysql -h${host} -P${port} -u${username} -p${password} -s -N -e \"
       SELECT schema_name FROM information_schema.schemata
       WHERE schema_name NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema', 'mysql_innodb_cluster_metadata')
     \")

     if [ -z \"\$db_list\" ]; then
       echo 'Error: No business databases found!'
       exit 1
     fi

     echo \"Target databases: \$db_list\"

     # 执行备份
     mysqldump -h${host} -P${port} -u${username} -p${password} \
         --single-transaction \
         --quick \
         --databases \$db_list \
         --set-gtid-purged=OFF \
         --routines --events --triggers | gzip > /backup/${fileName}
   "

# 4. 检查结果
if [ $? -eq 0 ]; then
  echo "--------------------------------------"
  echo "Backup SUCCESS: ${backUpFolder}/${fileName}"
  # 验证命令：查看备份中包含的库
  echo "Contains databases:"
  zcat "${backUpFolder}/${fileName}" | grep "Current Database:"
else
  echo "Backup FAILED!"
  exit 1
fi

# 5. 自动清理（30天前）
find "${backUpFolder}" -mtime +30 -type f -name "business_only_*.sql.gz" -exec rm -f {} \;