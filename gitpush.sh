#!/usr/bin/env bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/gitpush.sh
set -euo pipefail

if [[ "${1:-}" == "--dry-run" ]]; then
  echo "Dry-run: 未暂存、提交或推送任何文件。"
  git status --short
  exit 0
fi

msg="${1:-update}"
git rev-parse --is-inside-work-tree >/dev/null

# 检查工作区将要提交的文件，避免误提交私钥、凭据和大文件。
SENSITIVE_PATTERN='\.(key|pem|p12|pfx|crt|cer|secret)$|(^|/)(id_rsa|id_ed25519)(\..*)?$|(^|/)kubeconfig$|(^|/)\.env(\..+)?$'
sensitive=""
large=""
while IFS= read -r -d '' file; do
  if [[ "$file" =~ $SENSITIVE_PATTERN ]]; then
    sensitive+="$file"$'\n'
  fi
  if [[ -f "$file" ]]; then
    size=$(wc -c < "$file")
    if (( size > 5242880 )); then
      large+="$file"$'\n'
    fi
  fi
done < <(git ls-files --cached --others --exclude-standard -z)

if [[ -n "$sensitive" || -n "$large" ]]; then
  [[ -z "$sensitive" ]] || printf '拒绝提交敏感文件：\n%s' "$sensitive" >&2
  [[ -z "$large" ]] || printf '拒绝提交超过 5 MiB 的文件：\n%s' "$large" >&2
  exit 1
fi

git add .
if git diff --cached --quiet; then
  echo "没有待提交的变更"
  exit 0
fi
git commit -m "$msg"
git push
