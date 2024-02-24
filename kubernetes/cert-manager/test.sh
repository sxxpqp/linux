cat <<EOF > test-resources.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: test
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: test-selfsigned
  namespace: test
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: selfsigned-cert
  namespace: test
spec:
  dnsNames:
    - nps.iot.store
  secretName: selfsigned-cert-tls
  issuerRef:
    name: test-selfsigned
EOF

```
kubectl apply -f test-resources.yaml
```

```
kubectl describe certificate -n test
```
```
kubectl delete -f test-resources.yaml
```

### ingress 自动创建证书 需服务80可以访问才可以颁发证书.
```
cat <<EOF > test-ClusterIssuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
    name: letsencrypt-prod
spec:
  acme:
    email: shuxx@zkturing.com
    preferredChain: ""
    privateKeySecretRef:
      name: letsencrypt-prod
    server: https://acme-v02.api.letsencrypt.org/directory
    solvers:
    - http01:
        ingress:
          class: nginx
EOF
cat <<EOF > test-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    # add an annotation indicating the issuer to use.
    cert-manager.io/cluster-issuer: letsencrypt-prod
  name: test-ingress
  namespace: test
spec:
  rules:
  - host: nps.iot.store
    http:
      paths:
      - pathType: Prefix
        path: /
        backend:
          service:
            name: go
            port:
              number: 8080
  tls: # < placing a host in the TLS config will determine what ends up in the cert's subjectAltNames
  - hosts:
    - nps.iot.store
    secretName: test-nps # < cert-manager will store the created certificate in this secret.
EOF
```