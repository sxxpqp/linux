#!/usr/bin/env bash
# Calico BGP-LB IP 自动分配器
# 安装后自动运行, 监听 LoadBalancer Service, 自动分配 externalIPs
set -euo pipefail

LB_CIDR="${LB_CIDR:-172.16.150.200/29}"
INTERVAL="${INTERVAL:-10}"

# 从 CIDR 生成可用 IP 列表
gen_ips() {
  local base=$(echo "$LB_CIDR" | cut -d/ -f1)
  local mask=$(echo "$LB_CIDR" | cut -d/ -f2)
  local octets=(${base//./ })
  local count=$(( 2 ** (32 - mask) - 2 ))  # 除去网络和广播
  for i in $(seq 1 $count); do
    echo "${octets[0]}.${octets[1]}.${octets[2]}.$((octets[3] + i))"
  done
}

# 拿已分配的 IP
used_ips() {
  kubectl get svc --all-namespaces -o json 2>/dev/null | \
    python3 -c "
import sys,json
svcs = json.load(sys.stdin)
for s in svcs.get('items',[]):
    for ip in s.get('spec',{}).get('externalIPs',[]):
        print(ip)
    ip = s.get('spec',{}).get('loadBalancerIP','')
    if ip: print(ip)
" 2>/dev/null || \
  kubectl get svc --all-namespaces -o jsonpath='{range .items[*]}{.spec.externalIPs[*]}{"\n"}{.spec.loadBalancerIP}{"\n"}{end}' 2>/dev/null
}

while true; do
  # 找第一个未用的 IP
  next_ip=""
  used=$(used_ips 2>/dev/null)
  for ip in $(gen_ips); do
    if ! echo "$used" | grep -qF "$ip"; then
      next_ip="$ip"; break
    fi
  done

  if [ -z "$next_ip" ]; then
    echo "[$(date +%H:%M:%S)] IP 池已满, 等 ${INTERVAL}s..."
    sleep "$INTERVAL"
    continue
  fi

  # 找 Pending 的 LoadBalancer Service
  SVC=$(kubectl get svc --all-namespaces -o json 2>/dev/null | python3 -c "
import sys,json
svcs = json.load(sys.stdin)
for s in svcs.get('items',[]):
    if s.get('spec',{}).get('type') == 'LoadBalancer':
        ext = s.get('spec',{}).get('externalIPs',[])
        lbip = s.get('spec',{}).get('loadBalancerIP','')
        lb_status = s.get('status',{}).get('loadBalancer',{}).get('ingress',[])
        if not ext and not lbip and not lb_status:
            print(f\"{s['metadata']['namespace']}/{s['metadata']['name']}\")
" 2>/dev/null | head -1)

  if [ -n "$SVC" ]; then
    ns="${SVC%/*}"; name="${SVC#*/}"
    echo "[$(date +%H:%M:%S)] 分配 $next_ip → $ns/$name"
    kubectl -n "$ns" patch svc "$name" --type=merge \
      -p "{\"spec\":{\"externalIPs\":[\"$next_ip\"]}}" 2>/dev/null || true
  fi

  sleep "$INTERVAL"
done
