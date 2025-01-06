#### 卸载docker
```
sudo snap remove docker
```


### 安装docker 把安装脚本和离线软件下载对应目录即可 /opt
```
wget  https://chfs.sxxpqp.top:8443/chfs/shared/docker/aarch64/install-docker-offline.sh
```


### 测试docker run hello-world 内网不用测试

```
docker run hello-world
```


### 部署harbor arm版本的
```
wget https://chfs.sxxpqp.top:8443/chfs/shared/docker/docker-compose/harbor/harbor-offline-installer-aarch64-v2.10.1.tgz
```

### 生成dockerhub.kubekey.local证书
```
openssl genrsa -out ca.key 4096
```
```
openssl req -x509 -new -nodes -sha512 -days 3650 \
 -subj "/C=CN/ST=Beijing/L=Beijing/O=example/OU=Personal/CN=dockerhub.kubekey.local" \
 -key ca.key \
 -out ca.crt
```

```
openssl genrsa -out harbor.local.key 4096
```

```
openssl req -sha512 -new \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=example/OU=Personal/CN=dockerhub.kubekey.local" \
    -key harbor.local.key \
    -out harbor.local.csr
```
```
cat > v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1=dockerhub.kubekey.local
DNS.2=192.168.31.216
EOF
```


```
openssl x509 -req -sha512 -days 3650 \
    -extfile v3.ext \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
    -in harbor.local.csr \
    -out harbor.local.crt
```


```
mv harbor.local.crt dockerhub.kubekey.local.crt
mv harbor.local.key dockerhub.kubekey.local.key
```
为什么需要配置 Docker 证书呢？

配置Docker客户端以便它能够安全地与使用了自签名证书的Harbor仓库进行通信。默认情况下，Docker客户端在尝试与仓库通信时，会检查仓库的SSL证书是否由一个受信任的证书颁发机构（CA）签发。如果证书是自签名的（如Harbor的默认设置），Docker客户端将拒绝连接，因为它不信任该证书。

下面的操作目的是配置Docker守护程序，使其能够信任并使用Harbor仓库的自签名SSL证书，从而安全地与之通信。这确保了Docker客户端和Harbor仓库之间的通信是加密的，并且可以防止中间人攻击。

1 转换证书
将 dockerhub.kubekey.local.crt 转换为 dockerhub.kubekey.local.cert，供 Docker 使用。

Docker守护程序将 .crt 文件解释为CA证书，并将 .cert 文件解释为客户端证书。
```
openssl x509 -inform PEM -in dockerhub.kubekey.local.crt -out dockerhub.kubekey.local.cert
```
2 复制证书到指定位置
将服务器证书、服务器私钥和CA文件复制到Harbor主机上的Docker证书文件夹中。必须首先创建适当的文件夹。

# 创建目录
```
mkdir -p /etc/docker/certs.d/dockerhub.kubekey.local/
```
# 如果不是使用443端口，则需要在后面指定使用的具体端口，例如8001
```
mkdir -p /etc/docker/certs.d/dockerhub.kubekey.local:8001/
```
```
cp dockerhub.kubekey.local.cert /etc/docker/certs.d/dockerhub.kubekey.local/
cp dockerhub.kubekey.local.key /etc/docker/certs.d/dockerhub.kubekey.local/
cp ca.crt /etc/docker/certs.d/dockerhub.kubekey.local/
```
3 重启Docker引擎
```
systemctl restart docker
```

#### 下载镜像
下载 KubeSphere 3.3.1 所需要的 ARM 镜像。
```
#!/bin/bash

docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/ks-console:v3.3.1
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/ks-controller-manager:v3.3.1
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/ks-installer:v3.3.1
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/ks-apiserver:v3.3.1
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/openpitrix-jobs:v3.3.1
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/alpine:3.14
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/kube-apiserver:v1.22.12
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/kube-scheduler:v1.22.12
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/kube-proxy:v1.22.12
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/kube-controller-manager:v1.22.12
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/provisioner-localpv:3.3.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/linux-utils:3.3.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/kube-controllers:v3.23.2
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/cni:v3.23.2
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/pod2daemon-flexvol:v3.23.2
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/node:v3.23.2
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/kube-state-metrics:v2.5.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/fluent-bit:v1.8.11
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/prometheus-config-reloader:v0.55.1
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/prometheus-operator:v0.55.1
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/thanos:v0.25.2
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/prometheus:v2.34.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/fluentbit-operator:v0.13.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/node-exporter:v1.3.1
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/kubectl:v1.22.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/notification-manager:v1.4.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/notification-tenant-sidecar:v3.2.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/notification-manager-operator:v1.4.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/alertmanager:v0.23.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/kube-rbac-proxy:v0.11.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/docker:19.03
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/pause:3.5
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/configmap-reload:v0.5.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/snapshot-controller:v4.0.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/kube-rbac-proxy:v0.8.0
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/coredns:1.8.0
docker pull kubesphereio/log-sidecar-injector:v1.2.0 # 1.1 没有arm
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/k8s-dns-node-cache:1.15.12
docker pull minio/mc:RELEASE.2020-11-25T23-04-07Z
docker pull minio/minio:RELEASE.2019-08-07T01-59-21Z
#docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/defaultbackend-amd64:1.4
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/redis:5.0.14-alpine
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/haproxy:2.3
docker pull registry.cn-beijing.aliyuncs.com/kubesphereio/opensearch:2.6.0
docker pull 、busybox:latest
docker pull kubesphere/fluent-bit:v2.0.6
```

这里使用 KubeSphere 阿里云镜像，其中有些镜像会下载失败。对于下载失败的镜像，可通过本地电脑，直接去 hub.docker.com 下载。例如：

```
docker pull kubesphere/fluent-bit:v2.0.6 --platform arm64
#官方ks-console:v3.3.1(arm版)在麒麟中跑不起来，据运维有术介绍，需要使用node14基础镜像。当在鲲鹏服务器准备自己构建时报错淘宝源https过期，使用https://registry.npmmirror.com仍然报错，于是放弃使用该3.3.0镜像，重命名为3.3.1
docker pull zl862520682/ks-console:v3.3.0
docker tag zl862520682/ks-console:v3.3.0 dockerhub.kubekey.local/kubesphereio/ks-console:v3.3.1
## mc和minio也需要重新拉取打tag
docker pull minio/minio:RELEASE.2020-11-25T22-36-25Z-arm64
docker tag  minio/minio:RELEASE.2020-11-25T22-36-25Z-arm64 dockerhub.kubekey.local/kubesphereio/minio:RELEASE
```
2.5 重命名镜像
重新给镜像打 tag，标记为私有仓库镜像
```
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/kube-controllers:v3.27.3  dockerhub.kubekey.local/kubesphereio/kube-controllers:v3.27.3
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/cni:v3.27.3  dockerhub.kubekey.local/kubesphereio/cni:v3.27.3
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/pod2daemon-flexvol:v3.27.3  dockerhub.kubekey.local/kubesphereio/pod2daemon-flexvol:v3.27.3
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/node:v3.27.3  dockerhub.kubekey.local/kubesphereio/node:v3.27.3
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/ks-console:v3.3.1  dockerhub.kubekey.local/kubesphereio/ks-console:v3.3.1
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/alpine:3.14  dockerhub.kubekey.local/kubesphereio/alpine:3.14
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/k8s-dns-node-cache:1.22.20  dockerhub.kubekey.local/kubesphereio/k8s-dns-node-cache:1.22.20
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/ks-controller-manager:v3.3.1  dockerhub.kubekey.local/kubesphereio/ks-controller-manager:v3.3.1
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/ks-installer:v3.3.1  dockerhub.kubekey.local/kubesphereio/ks-installer:v3.3.1
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/ks-apiserver:v3.3.1  dockerhub.kubekey.local/kubesphereio/ks-apiserver:v3.3.1
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/openpitrix-jobs:v3.3.1  dockerhub.kubekey.local/kubesphereio/openpitrix-jobs:v3.3.1
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/kube-apiserver:v1.22.12  dockerhub.kubekey.local/kubesphereio/kube-apiserver:v1.22.12
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/kube-proxy:v1.22.12  dockerhub.kubekey.local/kubesphereio/
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/kube-controller-manager:v1.22.12  dockerhub.kubekey.local/kubesphereio/kube-controller-manager:v1.22.12
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/kube-scheduler:v1.22.12  dockerhub.kubekey.local/kubesphereio/kube-scheduler:v1.22.12
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/provisioner-localpv:3.3.0  dockerhub.kubekey.local/kubesphereio/provisioner-localpv:3.3.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/linux-utils:3.3.0  dockerhub.kubekey.local/kubesphereio/linux-utils:3.3.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/kube-state-metrics:v2.5.0  dockerhub.kubekey.local/kubesphereio/kube-state-metrics:v2.5.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/fluent-bit:v1.8.11  dockerhub.kubekey.local/kubesphereio/fluent-bit:v1.8.11
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/prometheus-config-reloader:v0.55.1  dockerhub.kubekey.local/kubesphereio/prometheus-config-reloader:v0.55.1
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/prometheus-operator:v0.55.1  dockerhub.kubekey.local/kubesphereio/prometheus-operator:v0.55.1
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/thanos:v0.25.2  dockerhub.kubekey.local/kubesphereio/thanos:v0.25.2
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/prometheus:v2.34.0  dockerhub.kubekey.local/kubesphereio/prometheus:v2.34.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/fluentbit-operator:v0.13.0  dockerhub.kubekey.local/kubesphereio/fluentbit-operator:v0.13.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/node-exporter:v1.3.1  dockerhub.kubekey.local/kubesphereio/node-exporter:v1.3.1
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/kubectl:v1.22.0  dockerhub.kubekey.local/kubesphereio/kubectl:v1.22.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/notification-manager:v1.4.0  dockerhub.kubekey.local/kubesphereio/notification-manager:v1.4.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/notification-tenant-sidecar:v3.2.0  dockerhub.kubekey.local/kubesphereio/notification-tenant-sidecar:v3.2.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/notification-manager-operator:v1.4.0  dockerhub.kubekey.local/kubesphereio/notification-manager-operator:v1.4.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/alertmanager:v0.23.0  dockerhub.kubekey.local/kubesphereio/alertmanager:v0.23.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/kube-rbac-proxy:v0.11.0  dockerhub.kubekey.local/kubesphereio/kube-rbac-proxy:v0.11.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/docker:19.03  dockerhub.kubekey.local/kubesphereio/docker:19.03
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/metrics-server:v0.4.2  dockerhub.kubekey.local/kubesphereio/metrics-server:v0.4.2
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/pause:3.5  dockerhub.kubekey.local/kubesphereio/pause:3.5
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/configmap-reload:v0.5.0  dockerhub.kubekey.local/kubesphereio/configmap-reload:v0.5.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/snapshot-controller:v4.0.0  dockerhub.kubekey.local/kubesphereio/snapshot-controller:v4.0.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/mc:RELEASE.2019-08-07T23-14-43Z  dockerhub.kubekey.local/kubesphereio/mc:RELEASE.2019-08-07T23-14-43Z
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/minio:RELEASE.2019-08-07T01-59-21Z  dockerhub.kubekey.local/kubesphereio/minio:RELEASE.2019-08-07T01-59-21Z
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/kube-rbac-proxy:v0.8.0  dockerhub.kubekey.local/kubesphereio/kube-rbac-proxy:v0.8.0
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/coredns:1.8.0  dockerhub.kubekey.local/kubesphereio/coredns:1.8.0
<!-- docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/log-sidecar-injector:1.1  dockerhub.kubekey.local/kubesphereio/log-sidecar-injector:1.1 -->
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/defaultbackend-amd64:1.4  dockerhub.kubekey.local/kubesphereio/defaultbackend-amd64:1.4
docker tag  registry.cn-beijing.aliyuncs.com/kubesphereio/kube-proxy:v1.22.12  dockerhub.kubekey.local/kubesphereio/kube-proxy:v1.22.12
docker tag registry.cn-beijing.aliyuncs.com/kubesphereio/k8s-dns-node-cache:1.22.20 dockerhub.kubekey.local/kubesphereio/k8s-dns-node-cache:1.15.12
docker tag registry.cn-beijing.aliyuncs.com/kubesphereio/kube-controllers:v3.23.2    dockerhub.kubekey.local/kubesphereio/kube-controllers:v3.23.2
docker tag registry.cn-beijing.aliyuncs.com/kubesphereio/cni:v3.23.2   dockerhub.kubekey.local/kubesphereio/cni:v3.23.2
docker tag registry.cn-beijing.aliyuncs.com/kubesphereio/pod2daemon-flexvol:v3.23.2   dockerhub.kubekey.local/kubesphereio/pod2daemon-flexvol:v3.23.2
docker tag registry.cn-beijing.aliyuncs.com/kubesphereio/node:v3.23.2  dockerhub.kubekey.local/kubesphereio/node:v3.23.2
docker tag registry.cn-beijing.aliyuncs.com/kubesphereio/opensearch:2.6.0 dockerhub.kubekey.local/kubesphereio/opensearch:2.6.0
docker tag registry.cn-beijing.aliyuncs.com/kubesphereio/busybox:latest dockerhub.kubekey.local/kubesphereio/busybox:latest
docker tag kubesphere/fluent-bit:v2.0.6 dockerhub.kubekey.local/kubesphereio/fluent-bit:v2.0.6 # 也可重命名为v1.8.11，可省下后续修改fluent的yaml，这里采用后修改方式

```

2.6 推送镜像至 harbor 仓库

```
#!/bin/bash
#

docker load < ks3.3.1-images.tar.gz

docker login -u admin -p Harbor12345 dockerhub.kubekey.local

docker push dockerhub.kubekey.local/kubesphereio/ks-console:v3.3.1
docker push dockerhub.kubekey.local/kubesphereio/ks-controller-manager:v3.3.1
docker push dockerhub.kubekey.local/kubesphereio/ks-installer:v3.3.1
docker push dockerhub.kubekey.local/kubesphereio/ks-apiserver:v3.3.1
docker push dockerhub.kubekey.local/kubesphereio/openpitrix-jobs:v3.3.1
docker push dockerhub.kubekey.local/kubesphereio/alpine:3.14
docker push dockerhub.kubekey.local/kubesphereio/kube-apiserver:v1.22.12
docker push dockerhub.kubekey.local/kubesphereio/kube-scheduler:v1.22.12
docker push dockerhub.kubekey.local/kubesphereio/kube-proxy:v1.22.12
docker push dockerhub.kubekey.local/kubesphereio/kube-controller-manager:v1.22.12
docker push dockerhub.kubekey.local/kubesphereio/provisioner-localpv:3.3.0
docker push dockerhub.kubekey.local/kubesphereio/linux-utils:3.3.0
docker push dockerhub.kubekey.local/kubesphereio/kube-controllers:v3.23.2
docker push dockerhub.kubekey.local/kubesphereio/cni:v3.23.2
docker push dockerhub.kubekey.local/kubesphereio/pod2daemon-flexvol:v3.23.2
docker push dockerhub.kubekey.local/kubesphereio/node:v3.23.2
docker push dockerhub.kubekey.local/kubesphereio/kube-state-metrics:v2.5.0
docker push dockerhub.kubekey.local/kubesphereio/fluent-bit:v1.8.11
docker push dockerhub.kubekey.local/kubesphereio/prometheus-config-reloader:v0.55.1
docker push dockerhub.kubekey.local/kubesphereio/prometheus-operator:v0.55.1
docker push dockerhub.kubekey.local/kubesphereio/thanos:v0.25.2
docker push dockerhub.kubekey.local/kubesphereio/prometheus:v2.34.0
docker push dockerhub.kubekey.local/kubesphereio/fluentbit-operator:v0.13.0
docker push dockerhub.kubekey.local/kubesphereio/node-exporter:v1.3.1
docker push dockerhub.kubekey.local/kubesphereio/kubectl:v1.22.0
docker push dockerhub.kubekey.local/kubesphereio/notification-manager:v1.4.0
docker push dockerhub.kubekey.local/kubesphereio/notification-tenant-sidecar:v3.2.0
docker push dockerhub.kubekey.local/kubesphereio/notification-manager-operator:v1.4.0
docker push dockerhub.kubekey.local/kubesphereio/alertmanager:v0.23.0
docker push dockerhub.kubekey.local/kubesphereio/kube-rbac-proxy:v0.11.0
docker push dockerhub.kubekey.local/kubesphereio/docker:19.03
docker push dockerhub.kubekey.local/kubesphereio/pause:3.5
docker push dockerhub.kubekey.local/kubesphereio/configmap-reload:v0.5.0
docker push dockerhub.kubekey.local/kubesphereio/snapshot-controller:v4.0.0
docker push dockerhub.kubekey.local/kubesphereio/kube-rbac-proxy:v0.8.0
docker push dockerhub.kubekey.local/kubesphereio/coredns:1.8.0
<!-- docker push dockerhub.kubekey.local/kubesphereio/log-sidecar-injector:1.1 -->
docker push dockerhub.kubekey.local/kubesphereio/k8s-dns-node-cache:1.15.12
docker push dockerhub.kubekey.local/kubesphereio/mc:RELEASE.2019-08-07T23-14-43Z
docker push dockerhub.kubekey.local/kubesphereio/minio:RELEASE.2019-08-07T01-59-21Z
docker push dockerhub.kubekey.local/kubesphereio/defaultbackend-amd64:1.4
docker push dockerhub.kubekey.local/kubesphereio/redis:5.0.14-alpine
docker push dockerhub.kubekey.local/kubesphereio/haproxy:2.3
docker push dockerhub.kubekey.local/kubesphereio/opensearch:2.6.0
docker push dockerhub.kubekey.local/kubesphereio/busybox:latest
docker push dockerhub.kubekey.local/kubesphereio/fluent-bit:v2.0.6
```

cd ~
mkdir kubesphere
cd kubesphere/

# 选择中文区下载(访问 GitHub 受限时使用)
export KKZONE=cn

# 执行下载命令，获取最新版的 kk（受限于网络，有时需要执行多次）
curl -sfL https://get-kk.kubesphere.io | VERSION=v3.0.7 sh -
chmod +x kk

3.3 生成集群创建配置文件
创建集群配置文件，本示例中，选择 KubeSphere 3.3.1 和 Kubernetes 1.22.12。
./kk create config -f kubesphere-v331-v12212.yaml --with-kubernetes v1.22.12 --with-kubesphere v3.3.1
