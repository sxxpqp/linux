#!/usr/bin/env bash
# 单节点 etcd 灾难恢复专用。三 Master stacked etcd 请使用独立的集群级恢复方案。
set -euo pipefail

die() { printf '[etcd-restore] ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[etcd-restore] %s\n' "$*"; }

[[ "${ETCD_RESTORE_ACK_SINGLE_NODE:-}" == "I_UNDERSTAND_SINGLE_NODE_ONLY" ]] || die "仅允许明确确认的单节点恢复；需设置 ETCD_RESTORE_ACK_SINGLE_NODE=I_UNDERSTAND_SINGLE_NODE_ONLY"
[[ "${EUID}" -eq 0 ]] || die "必须由 root 执行"
for var in SNAPSHOT_PATH ETCD_NAME NODE_IP ETCD_DATA_DIR; do
  [[ -n "${!var:-}" ]] || die "必须显式设置 $var，禁止使用脚本内置生产路径"
done
[[ "$ETCD_NAME" =~ ^[a-zA-Z0-9._-]+$ ]] || die "ETCD_NAME 格式不合法"
[[ "$NODE_IP" =~ ^[0-9a-fA-F:.]+$ ]] || die "NODE_IP 仅支持明确的 IP 地址"
[[ "$ETCD_DATA_DIR" == /* && "$ETCD_DATA_DIR" != "/" ]] || die "ETCD_DATA_DIR 必须为非根绝对路径"
[[ -f "$SNAPSHOT_PATH" && -s "$SNAPSHOT_PATH" ]] || die "快照不存在或为空"
[[ ! -e "$ETCD_DATA_DIR" ]] || die "数据目录已存在，拒绝覆盖；请先离线备份并迁移原目录"
[[ -f /etc/kubernetes/manifests/etcd.yaml ]] || die "未发现 kubeadm stacked etcd manifest；拒绝猜测拓扑"

# 拒绝运行中恢复：kubelet 可能重新创建静态 Pod，必须人工停用并验证。
if command -v crictl >/dev/null 2>&1; then
  [[ -z "$(crictl ps -q --name '^etcd$')" ]] || die "etcd 容器仍在运行，先完成停机和恢复预案"
else
  die "缺少 crictl，无法确认 etcd 是否仍在运行"
fi
[[ "${ETCD_RESTORE_ACK_STOPPED:-}" == "I_VERIFIED_ETCD_STOPPED" ]] || die "还需设置 ETCD_RESTORE_ACK_STOPPED=I_VERIFIED_ETCD_STOPPED"

ETCDUTL_BIN="${ETCDUTL_BIN:-/usr/local/bin/etcdutl}"
[[ -x "$ETCDUTL_BIN" ]] || die "缺少 etcdutl：$ETCDUTL_BIN（etcd 3.5+ 推荐使用 etcdutl）"
"$ETCDUTL_BIN" snapshot status "$SNAPSHOT_PATH" -w table || die "快照校验失败"

INITIAL_CLUSTER="${ETCD_NAME}=https://${NODE_IP}:2380"
log "即将执行单节点快照恢复：name=$ETCD_NAME, peer=$NODE_IP, data-dir=$ETCD_DATA_DIR"
[[ "${ETCD_RESTORE_ACK_TARGET:-}" == "$ETCD_DATA_DIR" ]] || die "必须设置 ETCD_RESTORE_ACK_TARGET 为完整目标数据目录，以确认恢复目标"

"$ETCDUTL_BIN" snapshot restore "$SNAPSHOT_PATH" \
  --name "$ETCD_NAME" \
  --data-dir "$ETCD_DATA_DIR" \
  --initial-cluster "$INITIAL_CLUSTER" \
  --initial-advertise-peer-urls "https://${NODE_IP}:2380"

chmod 700 "$ETCD_DATA_DIR"
log "恢复到新数据目录完成。请核对 etcd manifest 的 data-dir、成员拓扑和 TLS，再人工启动并验收。"
