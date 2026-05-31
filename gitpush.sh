#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/gitpush.sh
set -e

msg="${1:-update}"

# ── 防护检查 ────────────────────────────────────────────────────────────────

# 1. 检查敏感文件（私钥 / 证书 / 凭据）
# SENSITIVE_PATTERN='\.(key|pem|p12|pfx|crt|cer|secret)$|^(id_rsa|id_ed25519)(\..*)?$|kubeconfig$|\.env(\..+)?$'
# sensitive=$(git diff --cached --name-only | grep -Eie "$SENSITIVE_PATTERN" || true)
# if [[ -n "$sensitive" ]]; then
#   echo "❌ 检测到敏感文件，已中止提交："
#   echo "$sensitive"
#   echo "   如确认要提交，请先手动 git add 并绕过本脚本直接 git commit。"
#   exit 1
# fi

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
