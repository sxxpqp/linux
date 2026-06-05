#!/usr/bin/env bash
# Calico BGP-LB IP 自动分配器 — 纯 kubectl jsonpath, 不需要 python3
set -euo pipefail

LB_CIDR="${LB_CIDR:-172.16.150.200/29}"
INTERVAL="${INTERVAL:-10}"

gen_ips() {
  local base="${LB_CIDR%/*}"
  local mask="${LB_CIDR#*/}"
  local IFS=.; local o=($base)
  local count=$(( (1 << (32 - mask)) - 2 ))
  local i=1
  while [ $i -le $count ]; do
    printf '%d.%d.%d.%d\n' "${o[0]}" "${o[1]}" "${o[2]}" "$((o[3] + i))"
    i=$((i + 1))
  done
}

used_ips() {
  kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.externalIPs[*]}{"\n"}{.spec.loadBalancerIP}{"\n"}{end}' 2>/dev/null | sort -u
}

allocated_ips=""

while true; do
  next_ip=""
  used=$(used_ips 2>/dev/null)
  for ip in $(gen_ips); do
    if ! echo "$used" | grep -qFx "$ip"; then
      next_ip="$ip"; break
    fi
  done

  if [ -z "$next_ip" ]; then
    sleep "$INTERVAL"; continue
  fi

  # 找没有 externalIPs 的 LoadBalancer Service
  lines=$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.spec.externalIPs}{"\n"}{end}' 2>/dev/null)

  target=""
  while IFS=' ' read -r svc ext; do
    [ -z "$ext" ] || continue  # 已经有 externalIP
    [ "$ext" != "[]" ] || continue
    [ -n "$target" ] || target="$svc"
  done <<< "$lines"

  if [ -n "$target" ]; then
    ns="${target%/*}"; name="${target#*/}"
    echo "[$(date +%H:%M:%S)] 分配 $next_ip → $ns/$name"
    kubectl -n "$ns" patch svc "$name" --type=merge \
      -p "{\"spec\":{\"externalIPs\":[\"$next_ip\"]}}" 2>/dev/null || echo "  (patch 失败, Service 可能已被删除)"
    allocated_ips="$allocated_ips $next_ip"
  fi

  sleep "$INTERVAL"
done
