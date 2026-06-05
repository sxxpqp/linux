# 给 ServiceAccount 生成 kubeconfig

> 源: https://github.com/sxxpqp/linux/blob/main/kubernetes/rbac/generate-kubeconfig.md
> 状态: 验证过

把一个 namespace 内 SA 的 token + CA 证书,拼成一个独立 `kubeconfig` 文件,可以发给 UI / CI 用最小权限访问集群。

## 整体流程(7 步)

| 步 | 做什么 | 用什么 |
|---|---|---|
| 1 | 建 SA | `kubectl create sa` |
| 2 | 建 Role(允许做什么) | `Role` yaml |
| 3 | 建 RoleBinding(把 Role 绑给 SA) | `RoleBinding` yaml |
| 4 | 取 SA 的 token 和 CA 证书 | `kubectl get secret` |
| 5 | `kubectl config set-cluster` | 配 apiserver 地址 + CA |
| 6 | `kubectl config set-credentials` | 配 token |
| 7 | `kubectl config set-context` + `use-context` | 把 cluster 和 credentials 绑成 context |

---

## 1. 创建 ServiceAccount

```bash
kubectl create sa my-sa -n tmc-v2-test
```

## 2. 创建 Role(本例:只读 `apps/deployments`)

```bash
cat > role-sa.yaml << 'EOF'
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
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]
EOF

kubectl create -f role-sa.yaml -n tmc-v2-test
```

## 3. 创建 RoleBinding

```bash
cat > myrolebinding.yaml << 'EOF'
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

## 4. 取出 SA 的 token 和 CA 证书

```bash
# 找到 SA 关联的 secret(K8s 1.24 前自动创建;1.24+ 需要手动 kubectl create token)
kubectl get secret -n tmc-v2-test | grep my-sa

# 把 CA 证书取出来(secret 名替换成你看到的)
kubectl get secret my-sa-token-rl2df -n tmc-v2-test -oyaml \
  | grep 'ca.crt:' | awk '{print $2}' | base64 -d > /home/ca.crt
```

> ⚠ K8s 1.24+ SA 不再自动建 token Secret。两种方式之一:
> - 短期 token: `kubectl create token my-sa -n tmc-v2-test --duration=24h`
> - 长期 token: 手动建 `kubernetes.io/service-account-token` 类型的 Secret

## 5. 配置集群入口(`set-cluster`)

> `test-arm` = 集群别名(自己起),`139.198.122.166:6443` 改成你的 apiserver 地址。

### 内网 apiserver(用 CA 证书校验)

```bash
kubectl config set-cluster test-arm \
  --server=https://139.198.122.166:6443 \
  --certificate-authority=/home/ca.crt \
  --embed-certs=true \
  --kubeconfig=/home/test.config
```

### 公网 apiserver(跳过 TLS 校验,**不推荐生产**)

```bash
kubectl config set-cluster test-arm \
  --server=https://139.198.122.166:6443 \
  --kubeconfig=/home/test.config \
  --insecure-skip-tls-verify=true
```

## 6. 配置用户 token(`set-credentials`)

```bash
# 取 token(secret 名替换成你的)
token=$(kubectl describe secret my-sa-token-rl2df -n tmc-v2-test \
  | awk '/token:/{print $2}')

# 写入 kubeconfig
kubectl config set-credentials ui-admin \
  --token=$token \
  --kubeconfig=/home/test.config
```

## 7. 创建 context 并切换

```bash
kubectl config set-context ui-admin@test \
  --cluster=test-arm \
  --user=ui-admin \
  --kubeconfig=/home/test.config

kubectl config use-context ui-admin@test \
  --kubeconfig=/home/test.config
```

## 验证

```bash
kubectl get pod -n test --kubeconfig=/home/test.config
```

应该能看到 Pod 列表(且仅限于 Role 授权的范围 — 这里 SA 只有 `apps/deployments` 权限,`get pod` 应该报 forbidden,除非另加 Role)。
