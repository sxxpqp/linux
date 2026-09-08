#!/bin/bash
cd "$(dirname "$0")"

FULL_DIR=$1    # 传入全量备份目录名，比如 full_20260907_020000
shift
INC_DIRS=("$@")  # 后续参数是要合并的增量目录，按时间顺序传入

if [ -z "$FULL_DIR" ]; then
    echo "用法: ./restore.sh full_20260907_020000 inc_20260907_060000 inc_20260907_100000 ..."
    exit 1
fi

echo "=== 1. Prepare 全量备份（apply-log-only） ==="
docker compose exec -T xtrabackup xtrabackup \
  --prepare --apply-log-only \
  --target-dir=/backup/${FULL_DIR}

# 依次合并每个增量，除了最后一个都要加 --apply-log-only
TOTAL=${#INC_DIRS[@]}
for i in "${!INC_DIRS[@]}"; do
    INC=${INC_DIRS[$i]}
    if [ "$i" -eq $((TOTAL - 1)) ]; then
        # 最后一个增量，不加 apply-log-only
        echo "=== 合并最后一个增量: ${INC} ==="
        docker compose exec -T xtrabackup xtrabackup \
          --prepare \
          --target-dir=/backup/${FULL_DIR} \
          --incremental-dir=/backup/${INC}
    else
        echo "=== 合并增量: ${INC} ==="
        docker compose exec -T xtrabackup xtrabackup \
          --prepare --apply-log-only \
          --target-dir=/backup/${FULL_DIR} \
          --incremental-dir=/backup/${INC}
    fi
done

# 如果没有任何增量，全量自己就是最后一步，需要单独再 prepare 一次去掉 apply-log-only
if [ "$TOTAL" -eq 0 ]; then
    echo "=== 无增量，单独 prepare 全量为最终态 ==="
    docker compose exec -T xtrabackup xtrabackup \
      --prepare \
      --target-dir=/backup/${FULL_DIR}
fi

echo "=== 2. 停止 MySQL 容器 ==="
docker compose stop mysql

echo "=== 3. 清空原数据卷内容（危险操作，确认无误后再继续）==="
read -p "确认要清空当前 mysql_data 卷并恢复吗？(yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "已取消"
    exit 1
fi

docker compose exec -T xtrabackup sh -c "rm -rf /var/lib/mysql/*"
# 注意：这里挂载的是 ro（只读），实际清空需要改成可写模式或用其他方式，见下方说明

echo "=== 4. Copy-back 恢复数据 ==="
docker compose exec -T xtrabackup xtrabackup \
  --copy-back \
  --target-dir=/backup/${FULL_DIR} \
  --datadir=/var/lib/mysql

echo "=== 5. 修复文件权限并重启 MySQL ==="
docker compose exec -T xtrabackup chown -R 999:999 /var/lib/mysql   # mysql镜像内mysql用户通常是999
docker compose start mysql

echo "恢复完成！"