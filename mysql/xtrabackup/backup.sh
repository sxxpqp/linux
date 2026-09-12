#!/bin/bash
cd "$(dirname "$0")"

DATE=$(date "+%Y%m%d_%H%M%S")
LAST_BACKUP_FILE="backup/.last_backup_dir"
DB_USER="root"
DB_PASS="Xl123456.."

if [ ! -s "$LAST_BACKUP_FILE" ]; then
    # 文件不存在 或者 文件为空(-s 判断非空)，都走全量分支
    echo "=== 执行全量备份 ==="
    TARGET="full_${DATE}"
    docker exec xtrabackup mkdir -p "/backup/${TARGET}"

    docker exec xtrabackup xtrabackup \
      --backup \
      --datadir=/var/lib/mysql \
      --target-dir=/backup/${TARGET} \
      --user=${DB_USER} --password=${DB_PASS} \
      --host=mysql --port=3306

    if [ $? -eq 0 ] && [ -f "backup/${TARGET}/xtrabackup_checkpoints" ]; then
        echo "backup/${TARGET}" > "$LAST_BACKUP_FILE"
        echo "全量备份成功: backup/${TARGET}"
    else
        echo "全量备份失败！不更新记录文件"
        exit 1
    fi
else
    LAST_DIR=$(cat "$LAST_BACKUP_FILE")
    echo "=== 执行增量备份（基于 ${LAST_DIR}） ==="
    TARGET="inc_${DATE}"
    docker exec xtrabackup mkdir -p "/backup/${TARGET}"

    docker exec xtrabackup xtrabackup \
      --backup \
      --datadir=/var/lib/mysql \
      --target-dir=/backup/${TARGET} \
      --incremental-basedir=/backup/$(basename ${LAST_DIR}) \
      --user=${DB_USER} --password=${DB_PASS} \
      --host=mysql --port=3306

    if [ $? -eq 0 ] && [ -f "backup/${TARGET}/xtrabackup_checkpoints" ]; then
        echo "backup/${TARGET}" > "$LAST_BACKUP_FILE"
        echo "增量备份成功: backup/${TARGET}"
    else
        echo "增量备份失败！不更新记录文件，保留上一次有效记录: ${LAST_DIR}"
        exit 1
    fi
fi