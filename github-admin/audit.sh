#!/usr/bin/env bash
# Read-only GitHub repository inventory audit. Requires gh and jq.
set -Eeuo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd)"
manifest="$here/repositories.json"
report_dir="$here/reports"

for cmd in gh jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'Missing dependency: %s\n' "$cmd" >&2
    exit 2
  fi
done

jq -e '
  .schema_version == 1
  and (.owner | type == "string")
  and (.protected | type == "array")
  and (.upstream_references | type == "array")
' "$manifest" >/dev/null

gh auth status >/dev/null
owner="$(jq -r '.owner' "$manifest")"
mkdir -p -- "$report_dir"
chmod 700 -- "$report_dir"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
report="$report_dir/$owner-repos-$timestamp.json"

# Listing is read-only. Reports can include private repo metadata, so don't commit them.
gh repo list "$owner" --limit 1000 \
  --json nameWithOwner,url,isFork,isArchived,isPrivate,description > "$report"

count="$(jq 'length' "$report")"
printf 'GitHub owner: %s | visible repositories: %s\n' "$owner" "$count"
if (( count >= 1000 )); then
  echo 'WARNING: 1000-item limit reached; inventory may be incomplete.' >&2
fi

fail=0
printf '\nProtected repositories:\n'
while IFS= read -r name; do
  if jq -e --arg n "$name" 'any(.[]; .nameWithOwner == $n)' "$report" >/dev/null; then
    printf '  OK       %s\n' "$name"
  else
    printf '  MISSING  %s\n' "$name"
    fail=1
  fi
done < <(jq -r '.protected[].repo' "$manifest")

printf '\nPreviously non-visible upstream copies (observation only):\n'
while IFS=$'\t' read -r previous upstream; do
  if jq -e --arg n "$previous" 'any(.[]; .nameWithOwner == $n)' "$report" >/dev/null; then
    printf '  PRESENT  %s (upstream: %s)\n' "$previous" "$upstream"
  else
    printf '  ABSENT   %s (upstream: %s)\n' "$previous" "$upstream"
  fi
done < <(jq -r '.upstream_references[] | [.previous_repo, .upstream] | @tsv' "$manifest")

printf '\nSaved local audit snapshot: %s\n' "$report"
echo 'No GitHub repository was changed by this script.'
exit "$fail"
