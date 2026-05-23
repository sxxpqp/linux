https://mp.weixin.qq.com/s/xcVabXMk72BiqPMtR-hPUg




kubectl create secret docker-registry dockerhub \
  --docker-server=hub.wishfoxs.com:6443 \
  --docker-username=[USERNAME] \
  --docker-password=[PASSWORD] \
  --dry-run=client -o json | jq -r '.data.".dockerconfigjson"' | base64 -d > /tmp/config.json \
  && kubectl create secret generic docker-config --from-file=/tmp/config.json \
  && rm -f /tmp/config.json

# 验证一下
kubectl get secret docker-config -o jsonpath='{.data.config\.json}' | base64 -d
