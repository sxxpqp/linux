# Ingress — ingress-nginx v1.15.1 DaemonSet + hostNetwork

裸金属 K8s 入口方案：DaemonSet + hostNetwork, 节点 80/443 直通。

## TL;DR

```bash
# 安装(给 node1/node2 打标签 + 部署)
bash install.sh --label-nodes=node1,node2

# 卸载
bash uninstall.sh --apply

# 验证(装完后)
curl -I http://<ingress-node-ip>:80   # 期望: 404 Not Found(controller 在 listen)
```

## 文件

| 文件 | 状态 | 说明 |
|---|---|---|
| [install.sh](install.sh) | ✅ | 安装脚本: 打节点标签 → apply deploy.yaml → 等 DS/Jobs ready → 验证 80 端口 |
| [uninstall.sh](uninstall.sh) | ✅ | 卸载脚本: 删 DS → 清 Pod → 剥 namespace finalizer, 默认 dry-run |
| [deploy.yaml](deploy.yaml) | ✅ | ingress-nginx v1.15.1 完整部署(DaemonSet + hostNetwork + admission webhook) |
| [deploy-guide.md](deploy-guide.md) | 参考 | 改造思路 + 选型对比 + 镜像加速 |
| [test.sh](test.sh) | ✅ | **验证脚本**: 部署测试应用 → Pod→ClusterIP → 集群内 Ingress → 外部 Ingress, 装完跑 |
| [ingress-demo.yaml](ingress-demo.yaml) | 参考 | 最简 Ingress 示例 |
| [ingress-example.yaml](ingress-example.yaml) | 参考 | TLS + 多路径 rewrite 示例 |
| [test.yaml](test.yaml) | 参考 | 测试 Deployment + Service + Ingress |
| [values.yaml](values.yaml) | 参考 | Helm values(跟 deploy.yaml 互补) |

## 前置

```bash
# containerd registry.k8s.io 加速(每个节点)
mkdir -p /etc/containerd/certs.d/registry.k8s.io
cat > /etc/containerd/certs.d/registry.k8s.io/hosts.toml << EOF
server = "https://registry.k8s.io"
[host."https://k8s.ihome.sxxpqp.top:8443"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
EOF

# 打入口节点标签(或 install.sh --label-nodes= 自动打)
kubectl label node <node-name> ingress=true --overwrite
```

## 部署流程

详见 [deploy-guide.md](deploy-guide.md) — 4 个字段改造(Deployment→DaemonSet, hostNetwork, dnsPolicy, nodeSelector)。
