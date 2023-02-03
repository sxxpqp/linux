## 关于k3s的日常总结及分享

### k3s快速安装 

**k3s单节点适合频繁更换ip场景**

指定k3s版本，不指定INSTALL_K3S_VERSION就是最新的版本。

k3s的数据目录为data-dir: /var/lib/rancher/k3s

```
export INSTALL_K3S_VERSION=v1.21.14-k3s1
```

```
curl -sfL https://rancher-mirror.oss-cn-beijing.aliyuncs.com/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -
```
### 使用docker安装
```
curl -sfL https://rancher-mirror.oss-cn-beijing.aliyuncs.com/k3s/k3s-install.sh | INSTALL_K3S_MIRROR=cn sh -s - --docker


```
**安装完毕后可以在安装对应的kubesphere版本**
