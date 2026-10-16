#!/usr/bin/env bash
# 系统: Kubernetes (K8s)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/cert/update-tls-secret-all-namespaces.sh
# 用法: bash update-tls-secret-all-namespaces.sh --cert /path/fullchain.pem --key /path/privkey.pem [--apply]
set -euo pipefail
umask 077
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''

SECRET_NAME="${SECRET_NAME:-wishfox}"
CERT_FILE=""
KEY_FILE=""
APPLY=false
BACKUP_DIR="${BACKUP_DIR:-./tls-secret-backups-$(date +%Y%m%d-%H%M%S)}"
CONTEXT=""

usage() {
  echo "用法: $0 --cert <fullchain.pem> --key <privkey.pem> [--context <集群上下文>] [--apply]"
  echo "默认只预览。加 --apply 才会更新已有的 TLS Secret（默认名称 wishfox）。"
  echo "不会删除 Secret 或重启 Pod；证书能否自动生效取决于 Ingress/应用的热加载能力。"
  echo "依赖 Bash、kubectl、openssl、jq、date；每次更新都会创建独立备份子目录。"
  echo "可设置 SECRET_NAME 和 BACKUP_DIR 环境变量。"
}

while (($#)); do
  case "$1" in
    --cert|--key|--context)
      (($# >= 2)) || { usage >&2; exit 2; }
      [[ -n "$2" && "$2" != --* ]] || { usage >&2; exit 2; }
      case "$1" in
        --cert) CERT_FILE="$2" ;;
        --key) KEY_FILE="$2" ;;
        --context) CONTEXT="$2" ;;
      esac
      shift 2 ;;
    --apply) APPLY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$CERT_FILE" && -r "$CERT_FILE" && -n "$KEY_FILE" && -r "$KEY_FILE" ]] || {
  echo "必须提供可读取的 --cert 和 --key 文件" >&2
  exit 2
}
for cmd in kubectl openssl jq date; do
  command -v "$cmd" >/dev/null || { echo "缺少命令: $cmd" >&2; exit 2; }
done
openssl x509 -in "$CERT_FILE" -noout >/dev/null
openssl pkey -in "$KEY_FILE" -noout >/dev/null
# 过期或尚未生效的证书不能用于本次轮换；这里检查的是 fullchain 的第一张证书。
openssl x509 -in "$CERT_FILE" -checkend 0 -noout >/dev/null || {
  echo "新证书已过期，停止执行" >&2; exit 2;
}
not_before=$(openssl x509 -in "$CERT_FILE" -startdate -noout)
not_before=${not_before#notBefore=}
[[ $(date -d "$not_before" +%s) -le $(date +%s) ]] || {
  echo "新证书尚未生效，停止执行" >&2; exit 2;
}
cert_pub=$(openssl x509 -in "$CERT_FILE" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)
key_pub=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER | openssl dgst -sha256)
[[ "$cert_pub" == "$key_pub" ]] || { echo "证书与私钥不匹配" >&2; exit 2; }

# 固定本次使用的 context，避免运行期间切换默认 context 后误操作其他集群。
if [[ -z "$CONTEXT" ]]; then CONTEXT=$(kubectl config current-context); fi
CONTEXT=${CONTEXT//$'\r'/}
[[ -n "$CONTEXT" ]] || { echo "没有可用的 kubectl context" >&2; exit 2; }
kube() { kubectl --context "$CONTEXT" --request-timeout=30s "$@"; }
echo "[1/3] 检查通过，目标集群 context: $CONTEXT"
openssl x509 -in "$CERT_FILE" -noout -subject -dates

# 临时文件和正式备份都可能包含私钥，只允许当前用户访问。
work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
openssl base64 -A -in "$CERT_FILE" > "$work_dir/cert.b64"
openssl base64 -A -in "$KEY_FILE" > "$work_dir/key.b64"

# 获取命名空间失败时直接退出，不把失败误判为空列表。
ns_output=$(kube get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
ns_output=${ns_output//$'\r'/}
[[ -n "$ns_output" ]] || { echo "未获取到 namespace，停止执行" >&2; exit 1; }
mapfile -t namespaces <<< "$ns_output"

echo "[2/3] 查找已有 Secret: $SECRET_NAME | Namespace 数: ${#namespaces[@]} | 模式: $(if "$APPLY"; then echo 正式更新; else echo 仅预览; fi)"
if "$APPLY"; then
  mkdir -p -- "$BACKUP_DIR"
  chmod 700 -- "$BACKUP_DIR"
  # 即使复用 BACKUP_DIR 或同一秒执行多次，也不会覆盖上一次备份。
  run_backup_dir=$(mktemp -d "$BACKUP_DIR/run-$(date +%Y%m%d-%H%M%S)-XXXXXX")
  echo "本次原始 Secret 备份: $run_backup_dir（含私钥，请妥善保存）"
fi

updated=0
planned=0
skipped=0
failed=0
for ns in "${namespaces[@]}"; do
  # --ignore-not-found 只忽略对象不存在，权限和网络错误仍会报错。
  snapshot="$work_dir/secret.json"
  if ! kube get secret "$SECRET_NAME" -n "$ns" --ignore-not-found -o json > "$snapshot"; then
    echo "ERROR $ns: 无法读取 Secret（检查 RBAC / 集群连接）" >&2
    ((failed+=1))
    continue
  fi
  if [[ ! -s "$snapshot" ]]; then
    echo "跳过 $ns: 没有这个 Secret，不会新建"
    ((skipped+=1))
    continue
  fi
  type=$(jq -er '.type' "$snapshot") || {
    echo "ERROR $ns: Secret 数据无法解析" >&2
    ((failed+=1))
    continue
  }
  if [[ "$type" != "kubernetes.io/tls" ]]; then
    echo "SKIP $ns: 类型 $type"
    ((skipped+=1))
    continue
  fi
  if [[ $(jq -r '.immutable // false' "$snapshot") == true ]]; then
    echo "ERROR $ns: Secret 为 immutable，不能在不重建的情况下修改，已保留原样" >&2
    ((failed+=1))
    continue
  fi
  if jq -e --rawfile cert "$work_dir/cert.b64" --rawfile key "$work_dir/key.b64" \
      '.data["tls.crt"] == $cert and .data["tls.key"] == $key' "$snapshot" >/dev/null; then
    echo "跳过 $ns: 已经是这份证书和私钥"
    ((skipped+=1))
    continue
  fi
  if ! "$APPLY"; then
    echo "预览 $ns/$SECRET_NAME: 正式执行时会先备份，再原地替换证书和私钥"
    ((planned+=1))
    continue
  fi

  # 每个 Secret 更新前单独备份；绝不把 Secret JSON 打印到日志。
  if ! (set -o noclobber; cat "$snapshot" > "$run_backup_dir/$ns-$SECRET_NAME.json"); then
    echo "ERROR $ns: 备份失败，跳过更新" >&2
    ((failed+=1))
    continue
  fi
  # 证书与私钥放在同一个原子请求里更新；test 操作防止误改并发变更的对象。
  # JSON Patch 只能更新现有对象，Secret 被删除时会失败，不会重新创建。
  if ! jq -e --rawfile cert "$work_dir/cert.b64" --rawfile key "$work_dir/key.b64" '
      if (.metadata.uid | type) != "string" or (.metadata.resourceVersion | type) != "string"
      then error("missing object identity") else
      [ {op:"test", path:"/metadata/uid", value:.metadata.uid},
        {op:"test", path:"/metadata/resourceVersion", value:.metadata.resourceVersion},
        {op:"test", path:"/type", value:"kubernetes.io/tls"},
        {op:"add", path:"/data/tls.crt", value:$cert},
        {op:"add", path:"/data/tls.key", value:$key} ] end
      ' "$snapshot" > "$work_dir/patch.json"; then
    echo "ERROR $ns: 无法生成安全更新请求，未修改 Secret" >&2
    ((failed+=1))
    continue
  fi
  if kube patch secret "$SECRET_NAME" -n "$ns" --type=json --patch-file "$work_dir/patch.json" -o name; then
    echo "已更新 $ns/$SECRET_NAME: 未删除 Secret，未重启业务；请确认入口实际证书"
    ((updated+=1))
  else
    echo "ERROR $ns: 更新失败（备份已保留）" >&2
    ((failed+=1))
  fi
done

echo "[3/3] 完成: 待更新=$planned 已更新=$updated 跳过=$skipped 失败=$failed"
echo "本脚本不重启业务。Ingress/应用需要支持证书热加载；Secret 更新成功不等于 HTTPS 已加载新证书。"
((failed == 0))
