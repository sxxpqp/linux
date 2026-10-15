#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/gitpush.sh
set -e

msg="${1:-update}"

# ── 防护检查 ────────────────────────────────────────────────────────────────

# 1. 检查敏感文件（私钥 / 证书 / 凭据）
SENSITIVE_PATTERN='\\.(key|pem|p12|pfx|crt|cer|secret)$|(^|/)(id_rsa|id_ed25519)(\\..*)?$|(^|/)kubeconfig$|(^|/)\\.env(\\..+)?

# 2. 检查大文件（> 5 MB）
large=$(git diff --cached --name-only --diff-filter=ACMR -z | while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue
  size=$(wc -c < "$f")
  if (( size > 5242880 )); then printf '%s (%s MB)\\n' "$f" "$((size / 1048576))"; fi
done)
if [[ -n "$large" ]]; then
  printf '❌ 检测到超过 5 MB 的文件，已中止提交：\\n%s\\n' "$large"
  exit 1
fi

# ── 正式提交 ────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--dry-run" ]]; then
  echo "Dry-run: 未暂存、提交或推送任何文件。"
  git status --short
  exit 0
fi

git add .
# Check newly staged files before committing.
sensitive=$(git diff --cached --name-only --diff-filter=ACMR | grep -Ei "$SENSITIVE_PATTERN" || true)
if [[ -n "$sensitive" ]]; then
  printf '❌ 检测到敏感文件，已中止提交：\\n%s\\n' "$sensitive"
  exit 1
fi
large=$(git diff --cached --name-only --diff-filter=ACMR -z | while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue
  size=$(wc -c < "$f")
  if (( size > 5242880 )); then printf '%s\\n' "$f"; fi
done)
if [[ -n "$large" ]]; then
  printf '❌ 检测到超过 5 MB 的文件，已中止提交：\\n%s\\n' "$large"
  exit 1
fi
git diff --cached --quiet && { echo "没有待提交的变更"; exit 0; }
git commit -m "$msg"
git push

sensitive=$(git diff --cached --name-only --diff-filter=ACMR | grep -Ei "$SENSITIVE_PATTERN" || true)
if [[ -n "$sensitive" ]]; then
  printf '❌ 检测到敏感文件，已中止提交：\\n%s\\n' "$sensitive"
  exit 1
fi

# 2. 检查大文件（> 5 MB）
# large=$(git diff --cached --name-only | while read f; do
#   [[ -f "$f" ]] || continue
#   size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
#   [[ $size -gt 5242880 ]] && echo "$f ($(( size / 1024 / 1024 )) MB)"
# done)
# if [[ -n "$large" ]]; then
#   echo "⚠️  检测到大文件（> 5 MB），请确认是否要入库（离线包建议放 chfs/MinIO）："
#   echo "$large"
#   read -rp "继续提交？[y/N] " confirm
#   [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
# fi

# ── 正式提交 ────────────────────────────────────────────────────────────────

git add .
git commit -m "$msg"
git push
