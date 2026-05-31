#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/kind/test_ingress.sh
cd "$(dirname "$0")"

set -e

echo "=== 1. 部署 ingress-nginx ==="
kubectl apply -f ./ingress-nginx.yaml

echo "=== 2. 等待 ingress-nginx controller ready ==="
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s 2>/dev/null || {
  echo "等待超时，检查 ingress-nginx 命名空间下的 pod..."
  kubectl get pods -n ingress-nginx
  exit 1
}

echo "=== 3. 部署测试应用 ==="
kubectl apply -f ./test.yaml

echo "=== 4. 等待测试应用 ready ==="
kubectl wait --for=condition=ready pod -l app=hello --timeout=60s

echo ""
echo "=== 5. 测试 ingress ==="
sleep 5
result=$(curl -s -o /dev/null -w "%{http_code}" -H 'Host: hello.local' http://127.0.0.1)
if [ "$result" = "200" ]; then
  echo "✅ ingress 测试成功！返回状态码: $result"
else
  echo "❌ ingress 测试失败，状态码: $result"
fi
