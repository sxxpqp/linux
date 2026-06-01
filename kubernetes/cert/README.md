# 证书管理

Kubernetes 集群证书轮换与维护。

## 文件说明

| 文件 | 说明 |
|---|---|
| [k8s-cert-rotation.sh](k8s-cert-rotation.sh) | K8s 证书轮换脚本:kubeadm certs check-expiration 查看过期时间、备份旧证书至 /etc/kubernetes.old、kubeadm certs renew all 更新所有证书、重启相关组件、更新 kubeconfig |
| [k8s-cert-rotation-3masters.md](k8s-cert-rotation-3masters.md) | **3 master 节点生产环境**证书轮换完整手册:原理 / 影响范围 / 前置备份 / 串行更新 / 每节点验证 / 整体验证 / 回滚 / 常见坑 / 监控告警 |
