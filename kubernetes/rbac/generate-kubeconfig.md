```
kubectl create sa my-sa -n tmc-v2-test
```
```
cat>role-sa.yaml<<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: myrole
  namespace: tmc-v2-test
rules:
- apiGroups:
  - "apps"
  resources:
  - deployments
  verbs:
  - get
  - list
  - watch
EOF

kubectl create -f role-sa.yaml -n tmc-v2-test

```
```
cat>myrolebinding.yaml<<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: myrolebinding
  namespace: tmc-v2-test
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: myrole
subjects:
- kind: ServiceAccount
  name: my-sa
  namespace: tmc-v2-test
EOF

kubectl create -f myrolebinding.yaml -n tmc-v2-test

```
```
kubectl get secret -n tmc-v2-test |grep my-sa
kubectl get secret my-sa-token-rl2df -n tmc-v2-test -oyaml |grep ca.crt: | awk '{print $2}' |base64 -d > /home/ca.crt

```
设置集群访问方式，其中test-arm为需要访问的集群，10.0.1.100为集群apiserver地址（获取方法参见图1），/home/test.config为配置文件的存放路径。
如果通过内部apiserver地址，执行如下命令：
```
kubectl config set-cluster test-arm --server=https://139.198.122.166:6443  --certificate-authority=/home/ca.crt  --embed-certs=true --kubeconfig=/home/test.config
```
如果通过公网apiserver地址，执行如下命令：
```
kubectl config set-cluster test-arm --server=https://139.198.122.166:6443 --kubeconfig=/home/test.config --insecure-skip-tls-verify=true
```

```
token=$(kubectl describe secret my-sa-token-rl2df -n tmc-v2-test | awk '/token:/{print $2}')

```
```
kubectl config set-credentials ui-admin --token=$token --kubeconfig=/home/test.config
```

```
kubectl config set-context ui-admin@test --cluster=test-arm --user=ui-admin --kubeconfig=/home/test.config
```
```
kubectl config use-context ui-admin@test --kubeconfig=/home/test.config

```
```
kubectl get pod -n test --kubeconfig=/home/test.config
```