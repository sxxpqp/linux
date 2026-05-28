kubectl create configmap alloy-config \
  -n observability \
  --from-file=config.alloy=alloy-config.alloy \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart daemonset alloy -n observability

kubectl wait --for=condition=ready pod \
  -l app=alloy -n observability --timeout=60s

kubectl logs -n observability -l app=alloy --since=30s | tail -10