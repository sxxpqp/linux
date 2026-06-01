# Ingress 示例

Kubernetes Ingress 资源配置示例（demo、多路径路由、测试）。

## 文件

| 文件 | 说明 |
|---|---|
| [deploy.yaml](deploy.yaml) | 示例应用 Deployment + Service |
| [ingress-demo.yaml](ingress-demo.yaml) | 基础 Ingress 示例 |
| [ingress-example.yaml](ingress-example.yaml) | 多路径路由示例 |
| [test.yaml](test.yaml) | 测试 Pod |
| [test_ingress.sh](test_ingress.sh) | 测试脚本 |

## 前置：containerd registry.k8s.io 加速

```bash
mkdir -p /etc/containerd/certs.d/registry.k8s.io
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml << EOF
server = "https://registry.k8s.io"
[host."https://k8s.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF
```

## 给节点打 Ingress 标签

```bash
# 指定哪些节点跑 ingress-nginx pod
kubectl label node <node-name> ingress=true
```
