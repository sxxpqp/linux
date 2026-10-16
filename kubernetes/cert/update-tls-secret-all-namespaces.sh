#!/usr/bin/env bash
# 系统: Kubernetes (K8s)
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/cert/update-tls-secret-all-namespaces.sh
# 用法: bash update-tls-secret-all-namespaces.sh --cert /path/fullchain.pem --key /path/privkey.pem [--apply]
set -euo pipefail
umask 077

SECRET_NAME="${SECRET_NAME:-wishfox}"
CERT_FILE=""
KEY_FILE=""
APPLY=false
BACKUP_DIR="${BACKUP_DIR:-./tls-secret-backups-$(date +%Y%m%d-%H%M%S)}"

usage() {
  echo "用法: $0 --cert <fullchain.pem> --key <privkey.pem> [--apply]"
  echo "默认仅预览；--apply 更新所有 namespace 中已存在的 TLS Secret（名称默认 wishfox）。"
  echo "可设置 SECRET_NAME 和 BACKUP_DIR 环境变量。"
}

while (($#)); do
  case "$1" in
    --cert|--key)
      (($# >= 2)) || { usage >&2; exit 2; }
      if [[ "$1" == "--cert" ]]; then CERT_FILE="$2"; else KEY_FILE="$2"; fi
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
for cmd in kubectl openssl; do
  command -v "$cmd" >/dev/null || { echo "缺少命令: $cmd" >&2; exit 2; }
done
openssl x509 -in "$CERT_FILE" -noout >/dev/null
openssl pkey -in "$KEY_FILE" -noout >/dev/null
cert_pub=$(openssl x509 -in "$CERT_FILE" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256)
key_pub=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER | openssl dgst -sha256)
[[ "$cert_pub" == "$key_pub" ]] || { echo "证书与私钥不匹配" >&2; exit 2; }

# 获取命名空间失败时直接退出，不把失败误判为空列表。
ns_output=$(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ -n "$ns_output" ]] || { echo "未获取到 namespace，停止执行" >&2; exit 1; }
mapfile -t namespaces <<< "$ns_output"

echo "Secret: $SECRET_NAME | Namespace 总数: ${#namespaces[@]} | 模式: $(if "$APPLY"; then echo APPLY; else echo DRY-RUN; fi)"
if "$APPLY"; then
  mkdir -p -- "$BACKUP_DIR"
  chmod 700 -- "$BACKUP_DIR"
  echo "原始 Secret 备份目录: $BACKUP_DIR（含私钥，务必妥善保管）"
fi

updated=0
skipped=0
failed=0
for ns in "${namespaces[@]}"; do
  # 不吞掉权限/网络错误：先用 API 查询并区分 NotFound。
  if ! output=$(kubectl get secret "$SECRET_NAME" -n "$ns" -o json 2>&1); then
    if [[ "$output" == *"NotFound"* || "$output" == *"not found"* ]]; then
      echo "SKIP $ns: Secret 不存在"
      ((skipped+=1))
      continue
    fi
    echo "ERROR $ns: 无法读取 Secret（检查 RBAC / 集群连接）" >&2
    ((failed+=1))
    continue
  fi
  type=$(kubectl get secret "$SECRET_NAME" -n "$ns" -o jsonpath='{.type}') || {
    echo "ERROR $ns: 无法读取 Secret 类型" >&2
    ((failed+=1))
    continue
  }
  if [[ "$type" != "kubernetes.io/tls" ]]; then
    echo "SKIP $ns: 类型 $type"
    ((skipped+=1))
    continue
  fi
  if ! "$APPLY"; then
    echo "PLAN $ns/$SECRET_NAME"
    continue
  fi

  # 每个 Secret 更新前单独备份；绝不把 Secret JSON 打印到日志。
  if ! printf '%s\n' "$output" > "$BACKUP_DIR/$ns-$SECRET_NAME.json"; then
    echo "ERROR $ns: 备份失败，跳过更新" >&2
    ((failed+=1))
    continue
  fi
  if kubectl create secret tls "$SECRET_NAME" -n "$ns" --cert="$CERT_FILE" --key="$KEY_FILE" --dry-run=client -o yaml |
     kubectl apply -n "$ns" -f -; then
    echo "OK $ns/$SECRET_NAME"
    ((updated+=1))
  else
    echo "ERROR $ns: 更新失败（备份已保留）" >&2
    ((failed+=1))
  fi
done

echo "完成: 更新=$updated 跳过=$skipped 失败=$failed"
((failed == 0))
