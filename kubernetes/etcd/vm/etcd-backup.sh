#!/usr/bin/env bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/etcd/vm/etcd-backup.sh

set -euo pipefail

ETCDCTL_PATH='/usr/local/bin/etcdctl'
ENDPOINTS='https://192.168.1.57:2379'
ETCD_DATA_DIR="/var/lib/etcd"
BACKUP_ROOT="/var/backups/kube_etcd"
BACKUP_DIR="${BACKUP_ROOT}/etcd-$(date +%Y-%m-%d-%H-%M-%S)"
KEEPBACKUPNUMBER=6
ETCDBACKUPSCIPT='/usr/local/bin/kube-scripts'

ETCDCTL_CERT="/etc/ssl/etcd/ssl/admin-node1.pem"
ETCDCTL_KEY="/etc/ssl/etcd/ssl/admin-node1-key.pem"
ETCDCTL_CA_FILE="/etc/ssl/etcd/ssl/ca.pem"

mkdir -p "$BACKUP_DIR"

export ETCDCTL_API=2
"$ETCDCTL_PATH" backup --data-dir "$ETCD_DATA_DIR" --backup-dir "$BACKUP_DIR"

sleep 3

{
  export ETCDCTL_API=3
  "$ETCDCTL_PATH" --endpoints="$ENDPOINTS" snapshot save "$BACKUP_DIR/snapshot.db" \
    --cacert="$ETCDCTL_CA_FILE" \
    --cert="$ETCDCTL_CERT" \
    --key="$ETCDCTL_KEY"
} > /dev/null

sleep 3

mapfile -t backup_dirs < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'etcd-*' -printf '%f\n' | sort -r)

index=$KEEPBACKUPNUMBER
while ((index < ${#backup_dirs[@]})); do
  old_backup="${BACKUP_ROOT}/${backup_dirs[index]}"
  if [[ "$old_backup" == "$BACKUP_ROOT"/etcd-* ]]; then
    echo "删除旧备份: $old_backup"
    rm -rf -- "$old_backup"
  fi
  ((index += 1))
done
