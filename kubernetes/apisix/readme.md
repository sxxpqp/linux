helm repo add apisix https://charts.apiseven.com
helm repo update

helm install apisix apisix/apisix \
  --namespace apisix \
  --create-namespace \
  --set etcd.replicaCount=1 \
  --set etcd.persistence.enabled=true \
  --set etcd.persistence.size=8Gi \
  --set dashboard.enabled=true



helm repo add apisix https://apache.github.io/apisix-helm-chart
helm repo update
helm install apisix-dashboard apisix/apisix-dashboard --create-namespace --namespace apisix



helm repo add apisix https://apache.github.io/apisix-helm-chart
helm repo update
helm install apisix-ingress-controller apisix/apisix-ingress-controller --namespace ingress-apisix --create-namespace




helm repo add apisix https://charts.apiseven.com
helm repo update

helm install apisix apisix/apisix \
  --namespace apisix \
  --create-namespace \
  --set etcd.replicaCount=1 \
  --set etcd.persistence.enabled=true \
  --set etcd.persistence.size=8Gi \
  # 开启 Dashboard
  --set dashboard.enabled=true \
  # 开启 Ingress Controller
  --set ingress-controller.enabled=true \
  --set ingress-controller.config.apisix.serviceNamespace=apisix