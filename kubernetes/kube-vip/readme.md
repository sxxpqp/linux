# Kube-VIP

控制面高可用 VIP，以静态 Pod 形式跑在每个 Master 节点。

> v0.8.0 安装失败，稳定版本用 **v0.7.2**。

## 文件

| 文件/目录 | 说明 |
|---|---|
| [kube-vip.yaml](kube-vip.yaml) | 通用环境静态 Pod manifest |
| [kube-vip-aliyun.yaml](kube-vip-aliyun.yaml) | 阿里云环境 manifest |
| [deploy/deploy.yaml](deploy/deploy.yaml) | DaemonSet 部署模式（非静态 Pod） |

## 生成静态 Pod manifest

```bash
export VIP=192.168.215.200   # 改成实际 VIP
export INTERFACE=ens33        # ip a 查看实际网卡名

# 拉镜像（ctr 不走 containerd mirror，需写完整 Harbor 地址）
ctr image pull huball.ihome.sxxpqp.top:8443/plndr/kube-vip:v0.7.2

# 生成 manifest，写入每个控制节点
ctr run --rm --net-host huball.ihome.sxxpqp.top:8443/plndr/kube-vip:v0.7.2 vip \
  /kube-vip manifest pod \
  --interface $INTERFACE \
  --vip $VIP \
  --controlplane \
  --services \
  --arp \
  --leaderElection | tee /etc/kubernetes/manifests/kube-vip.yaml
```

**所有控制节点**都要执行，生成各自的 `/etc/kubernetes/manifests/kube-vip.yaml`。
