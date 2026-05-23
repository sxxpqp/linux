#!/bin/bash

# 安全配置：失败立即终止、禁止未定义变量、管道失败则整体失败
set -o errexit
set -o nounset
set -o pipefail

# 核心配置（根据自己的集群修改）
ETCDCTL_PATH='/usr/local/bin/etcdctl'
ENDPOINTS='https://127.0.0.1:2379'  # ETCD 节点IP
#ETCD_DATA_DIR="/var/lib/etcd"          # ETCD 数据目录（仅注释用，实际不用）
BACKUP_DIR="/var/backups/kube_etcd/etcd-$(date +%Y-%m-%d-%H-%M-%S)"
KEEPBACKUPNUMBER='30'                   # 保留最新的6个备份
# ETCD 证书配置（K8s 集群默认路径，无需修改）
ETCDCTL_CERT="/etc/kubernetes/pki/etcd/server.crt"
ETCDCTL_KEY="/etc/kubernetes/pki/etcd/server.key"
ETCDCTL_CA_FILE="/etc/kubernetes/pki/etcd/ca.crt"

# 日志函数：输出时间+内容，便于排查
log() {
          local log_time=$(/bin/date +%Y%m%d%H%M%S)
          echo "[$log_time] $1"
}

# 步骤1：创建备份目录
log "开始创建备份目录：$BACKUP_DIR"
[ ! -d $BACKUP_DIR ] && mkdir -p $BACKUP_DIR || log "备份目录已存在"

# 步骤2：执行 ETCD v3 快照备份（仅保留v3，删除v2冗余命令）
log "开始执行 ETCD 快照备份"
export ETCDCTL_API=3
$ETCDCTL_PATH --endpoints="$ENDPOINTS" snapshot save "$BACKUP_DIR/snapshot.db" \
    --cacert="$ETCDCTL_CA_FILE" \
    --cert="$ETCDCTL_CERT" \
    --key="$ETCDCTL_KEY"
# 取消 >/dev/null，保留正常输出；若失败，set -o errexit 会终止脚本

# 步骤3：校验快照有效性（核心！生产必须加）
#log "校验备份快照有效性"
#snapshot_status=$($ETCDCTL_PATH snapshot status "$BACKUP_DIR/snapshot.db" 2>&1)
#if [ $? -ne 0 ]; then
#    log "ERROR: 快照备份失败，快照文件损坏！错误信息：$snapshot_status"
#    rm -rf "$BACKUP_DIR"  # 删除损坏的备份，避免占用空间
#    exit 1
#fi
#log "快照校验成功：$snapshot_status"

# 步骤4：自动清理旧备份（保留最新6个）
log "开始清理旧备份，保留最新 $KEEPBACKUPNUMBER 个"
# 进入备份父目录，只过滤etcd-开头的目录，按反向时间排序（最新在前）
cd /var/backups/kube_etcd || exit 1
ls -1r | grep "^etcd-" | awk -v keep="$KEEPBACKUPNUMBER" '{if(NR > keep) print $1}' | while read -r old_backup; do
    log "删除旧备份：$old_backup"
    rm -rf "$old_backup"
     
done

log "ETCD 备份完成，备份目录：$BACKUP_DIR"
exit 0
