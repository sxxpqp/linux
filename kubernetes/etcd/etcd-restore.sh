# 1. 确认snapshot.db路径（替换为你的实际路径，比如/root/snapshot.db）
SNAPSHOT_PATH="/home/kh/snapshot.db" # 替换为实际路径
# 定义核心参数（根据你的集群调整）
ETCD_NAME="kh"  # etcd节点名称（与集群原有名称一致，可从etcd配置中查）
NODE_IP="192.168.214.128" # etcd节点IP地址 （与集群原有IP一致）

# 2. 确认etcdctl版本（需与etcd版本一致）
/usr/local/bin/etcdctl version
# 输出示例（需保证API版本为3）：
# etcdctl version: 3.5.9
# API version: 3.5

ETCD_DATA_DIR="/var/lib/etcd"  # etcd默认数据目录（恢复后会覆盖此目录）
INITIAL_CLUSTER="${ETCD_NAME}=https://${NODE_IP}:2380"
INITIAL_ADVERTISE_PEER_URLS="https://${NODE_IP}:2380"
ENDPOINTS="https://${NODE_IP}:2379"
CA_CERT="/etc/kubernetes/pki/etcd/ca.crt"
SERVER_CERT="/etc/kubernetes/pki/etcd/server.crt"
SERVER_KEY="/etc/kubernetes/pki/etcd/server.key"

# 1. 清空原有etcd数据目录（先备份过，放心删除）
if [ -d $ETCD_DATA_DIR ]; then
#  rm -rf $ETCD_DATA_DIR/*
# 提醒用户，请手动删除数据目录下的文件
  echo "请手动删除 $ETCD_DATA_DIR 目录下的所有文件后再运行此脚本！"
  #通过mv $ETCD_DATA_DIR /tmp/'etcd-backup-$(date +%Y%m%d%H%M%S) 进行备份
  echo "备份 $ETCD_DATA_DIR 目录到 /tmp/etcd-backup-$(date +%Y%m%d%H%M%S)"
  #   mv $ETCD_DATA_DIR /tmp/etcd-backup-$(date +%Y%m%d%H%M%S)
  exit 1
fi
#rm -rf $ETCD_DATA_DIR/*

# 2. 执行快照恢复（核心命令）
/usr/local/bin/etcdctl --endpoints=${ENDPOINTS} \
	--cacert=${CA_CERT} \
	--cert=${SERVER_CERT} \
	--key=${SERVER_KEY} \
	snapshot restore ${SNAPSHOT_PATH} \
	--name=${ETCD_NAME} \
	--data-dir=${ETCD_DATA_DIR} \
	--initial-cluster=${INITIAL_CLUSTER} \
	--initial-advertise-peer-urls=${INITIAL_ADVERTISE_PEER_URLS}

# 3. 修复etcd数据目录权限（必须！否则etcd启动失败）
chmod 700 $ETCD_DATA_DIR
