#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubeblocks/mysql/paxos/create-user.sh
# 创建 MySQL 业务账号并同步到 ProxySQL (Paxos 集群).
#
# Paxos 模式下找 leader pod (kubeblocks.io/role=leader), 在 leader 上建账号
# 同步到 ProxySQL mysql_users, 业务一次执行不用手动两遍.
#
# 用法:
#   bash create-user.sh --user app --pass apppass --db mydb
#   bash create-user.sh --user app --pass apppass --db mydb --readonly  # 只读账号
#   bash create-user.sh --user app --pass apppass --db mydb --skip-proxysql
set -uo pipefail

NS="test"
CLUSTER="mysql-paxos"
MYSQL_ROOT_PASS="mysql123"
PROXYSQL_ADMIN_PASS="admin"

NEW_USER=""
NEW_PASS=""
TARGET_DB=""
READONLY=false
SKIP_PROXYSQL=false

while [ $# -gt 0 ]; do
  case "$1" in
    --ns)             NS="$2"; shift 2 ;;
    --user)           NEW_USER="$2"; shift 2 ;;
    --pass)           NEW_PASS="$2"; shift 2 ;;
    --db)             TARGET_DB="$2"; shift 2 ;;
    --root-pass)      MYSQL_ROOT_PASS="$2"; shift 2 ;;
    --proxysql-pass)  PROXYSQL_ADMIN_PASS="$2"; shift 2 ;;
    --readonly)       READONLY=true; shift ;;
    --skip-proxysql)  SKIP_PROXYSQL=true; shift ;;
    -h|--help)
      sed -n '2,11p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

if [ -z "$NEW_USER" ] || [ -z "$NEW_PASS" ] || [ -z "$TARGET_DB" ]; then
  echo "ERROR: --user / --pass / --db 均为必填"
  echo "用法: bash create-user.sh --user app --pass apppass --db mydb"
  exit 1
fi

# ProxySQL hostgroup: 0=写(leader), 1=读(follower)
if [ "$READONLY" = true ]; then
  DEFAULT_HG=1
  GRANT_SQL="GRANT SELECT ON ${TARGET_DB}.* TO '${NEW_USER}'@'%';"
  PRIV_DESC="SELECT"
else
  DEFAULT_HG=0
  GRANT_SQL="GRANT ALL ON ${TARGET_DB}.* TO '${NEW_USER}'@'%';"
  PRIV_DESC="ALL"
fi

# ---------- 找 leader pod ----------
# apecloud-mysql 用 leader/follower 角色 (kubeblocks 统一在 kubeblocks.io/role 标签)
LEADER_POD=$(kubectl get pod -n "${NS}" \
  -l app.kubernetes.io/instance="${CLUSTER}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.kubeblocks\.io/role}{"\n"}{end}' \
  2>/dev/null | awk '$2=="leader"{print $1}' | head -1)

# 兼容老版本可能写 primary
if [ -z "$LEADER_POD" ]; then
  LEADER_POD=$(kubectl get pod -n "${NS}" \
    -l app.kubernetes.io/instance="${CLUSTER}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.kubeblocks\.io/role}{"\n"}{end}' \
    2>/dev/null | awk '$2=="primary"{print $1}' | head -1)
fi

if [ -z "$LEADER_POD" ]; then
  echo "ERROR: 找不到 leader pod, 检查集群状态:"
  echo "  kubectl get pod -n ${NS} -l app.kubernetes.io/instance=${CLUSTER} \\"
  echo "    -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.kubeblocks\\.io/role'"
  exit 1
fi

echo "========================================="
echo " 创建 MySQL 业务账号 (Paxos)"
echo "  namespace:    ${NS}"
echo "  cluster:      ${CLUSTER}"
echo "  leader pod:   ${LEADER_POD}"
echo "  user:         ${NEW_USER}"
echo "  database:     ${TARGET_DB}"
echo "  privileges:   ${PRIV_DESC}"
echo "  proxysql hg:  ${DEFAULT_HG} (0=写组 1=读组)"
echo "========================================="
echo ""

# ---------- 1. Paxos leader 建账号 ----------
echo "[1/2] MySQL leader 创建账号..."
kubectl exec -n "${NS}" "${LEADER_POD}" -c mysql -- \
  mysql -uroot -p"${MYSQL_ROOT_PASS}" --connect-timeout=10 -e "
CREATE USER IF NOT EXISTS '${NEW_USER}'@'%' IDENTIFIED BY '${NEW_PASS}';
${GRANT_SQL}
FLUSH PRIVILEGES;
" 2>/dev/null
echo "  ✓ MySQL 账号已创建 (Paxos 自动同步到 follower)"
echo ""

# ---------- 2. 同步到 ProxySQL ----------
if [ "$SKIP_PROXYSQL" = false ]; then
  PROXYSQL_POD=$(kubectl get pod -n "${NS}" \
    -l app.kubernetes.io/instance="${CLUSTER}" \
    -o name 2>/dev/null | grep proxysql | head -1 | sed 's|pod/||')

  if [ -z "$PROXYSQL_POD" ]; then
    echo "[2/2] ⚠ 未找到 ProxySQL pod, 跳过同步"
    echo "  如果 ProxySQL 还没部署, 后续部署后手动同步:"
    echo "    INSERT INTO mysql_users(username,password,default_hostgroup)"
    echo "      VALUES('${NEW_USER}','${NEW_PASS}',${DEFAULT_HG});"
    echo "    LOAD MYSQL USERS TO RUNTIME; SAVE MYSQL USERS TO DISK;"
  else
    echo "[2/2] 同步账号到 ProxySQL (pod: ${PROXYSQL_POD})..."
    kubectl exec -n "${NS}" "${PROXYSQL_POD}" -c proxysql -- \
      mysql -h127.0.0.1 -P6032 -uadmin -p"${PROXYSQL_ADMIN_PASS}" \
            --connect-timeout=10 -e "
INSERT INTO mysql_users(username,password,default_hostgroup,active)
  VALUES('${NEW_USER}','${NEW_PASS}',${DEFAULT_HG},1)
  ON DUPLICATE KEY UPDATE password='${NEW_PASS}', default_hostgroup=${DEFAULT_HG}, active=1;
LOAD MYSQL USERS TO RUNTIME;
SAVE MYSQL USERS TO DISK;
" 2>/dev/null
    echo "  ✓ ProxySQL 已同步"
  fi
else
  echo "[2/2] 跳过 ProxySQL 同步 (--skip-proxysql)"
fi

echo ""
echo "==============================================================="
echo " ✓ 账号创建完成"
echo "==============================================================="
echo ""
echo "连接信息 (通过 ProxySQL):"
echo "  host:     <proxysql-service>.${NS}.svc"
echo "  port:     6033"
echo "  user:     ${NEW_USER}"
echo "  password: ${NEW_PASS}"
echo "  database: ${TARGET_DB}"
echo ""
echo "验证账号:"
echo "  kubectl exec -n ${NS} ${LEADER_POD} -c mysql -- \\"
echo "    mysql -u${NEW_USER} -p'${NEW_PASS}' -e 'SHOW DATABASES;' 2>/dev/null"
