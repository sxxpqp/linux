#!/bin/bash

set -e

MYSQL_IP=turingcloud-mysql
MYSQL_PORT=3306
MYSQL_ADMIN_USER=root #Mysql管理员用户，通常为root
MYSQL_ADMIN_PWD=Iot@123456
MYSQL_CMD="mysql -h${MYSQL_IP} -P${MYSQL_PORT} -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PWD}"

#创建schema
init_msyql() {
    # [[ $# -eq 0 ]] && echo "ERROR:Schema Is Null,Please Excute:bash $0 -h" && exit 1
    for mysql_schema in $(ls sql_dir | cut -d. -f1); do
        {
            sql_name=${mysql_schema}.sql
            if ${MYSQL_CMD} -e "use ${mysql_schema}" &>/dev/null; then
                echo ${mysql_schema}数据库已存在
            else
                echo "INFO:Begin Create Mysql Schema ${mysql_schema}..."
                ${MYSQL_CMD} -e "create SCHEMA if NOT EXISTS ${mysql_schema} default character set utf8mb4 collate utf8mb4_bin;"
                echo "INFO:Begin Import ${sql_name} Sql To Schema ${mysql_schema} On Mysql User ${mysql_user}..."
                mysql -h${MYSQL_IP} -P${MYSQL_PORT} -u${MYSQL_ADMIN_USER} -p${MYSQL_ADMIN_PWD} ${mysql_schema} <sql_dir/${sql_name}

            fi
        } &
    done
    wait
}

init_msyql
if [ $? -eq 0 ]; then
    echo "数据库初始化完成"
fi

mc config host add minio http://turingcloud-minio:9000 minio Iot@123456 --api s3v4
if [ $? -eq 0 ]; then
    echo "minio添加远程配置成功"
fi
if mc mb minio/turing &>/dev/null; then
    echo "minio开始初始化"
    mc mirror turing/ minio/turing
else
    echo "minio的桶turing已存在"

fi
if mc mb minio/model &>/dev/null; then
    echo "minio的桶model创建成功"
else
    echo "minio的桶model已存在"

fi

if mc mb minio/vrw &>/dev/null; then
    echo "minio开始初始化"
    mc mirror vrw/ minio/vrw
    echo "minio的桶vrw创建成功,并同步数据完成"
    # # 设置桶的访问权限只读
    # mc policy set public minio/vrw

else
    echo "minio的桶vrw已存在"
    

fi

if [ $? -eq 0 ]; then
    mc policy  public minio/vrw &>/dev/null
    echo "minio初始化完成"
fi
