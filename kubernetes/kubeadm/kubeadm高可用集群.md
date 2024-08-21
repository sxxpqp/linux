### 先单节点安装

#### 配置高可用地址 kubeadm

#### --control-plane-endpoint 指定负载均衡地址 172.16.0.10:6443

#### --image-repository 指定阿里云镜像地址 registry.cn-hangzhou.aliyuncs.com/google_containers

#### --pod-network-cidr 指定 pod 网段

```
kubeadm init --apiserver-advertise-address $(hostname -i) --pod-network-cidr 10.5.0.0/16  --image-repository registry.cn-hangzhou.aliyuncs.com/google_containers
```

### 安装网络插件

```
kubectl apply -f https://raw.githubusercontent.com/cloudnativelabs/kube-router/master/daemonset/kubeadm-kuberouter.yaml
```

### 部署负载均衡 实现 kube-apiserver 高可用

#### 单独使用一台设备部署 kube-vip 静态 pod

```
cat >> /etc/kubernetes/manifests/kube-vip.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  creationTimestamp: null
  name: kube-vip
  namespace: kube-system
spec:
  containers:
  - args:
    - manager
    env:
    - name: vip_arp
      value: "true"
    - name: port
      value: "6443"
    - name: vip_interface
      value: ens33
    - name: vip_cidr
      value: "32"
    - name: cp_enable
      value: "true"
    - name: cp_namespace
      value: kube-system
    - name: vip_ddns
      value: "false"
    - name: svc_enable
      value: "true"
    - name: vip_leaderelection
      value: "true"
    - name: vip_leaseduration
      value: "5"
    - name: vip_renewdeadline
      value: "3"
    - name: vip_retryperiod
      value: "1"
    - name: address
      value: 172.16.0.
    image: iharbor.sxxpqp.top/library/kube-vip:v0.4.0
    imagePullPolicy: Always
    name: kube-vip
    resources: {}
    securityContext:
      capabilities:
        add:
        - NET_ADMIN
        - NET_RAW
        - SYS_TIME
    volumeMounts:
    - mountPath: /etc/kubernetes/admin.conf
      name: kubeconfig
  hostAliases:
  - hostnames:
    - kubernetes
    ip: 127.0.0.1
  hostNetwork: true
  volumes:
  - hostPath:
      path: /etc/kubernetes/admin.conf
    name: kubeconfig
status: {}
EOF
```

#### 获取 kubeadm-config

```
kubectl -n kube-system get configmap kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > kubeadm.yaml
```

#### 修改 kubeadm-config certSANs

```
apiServer:
  certSANs:
  - "172.16.0.10"
  - "10.96.0.1"
  - "127.0.0.1"
  - "172.16.0.2"
  - "172.16.0.3"
  - "172.16.0.4"
  extraArgs:
    authorization-mode: Node,RBAC
  timeoutForControlPlane: 4m0s
apiVersion: kubeadm.k8s.io/v1beta3
controlPlaneEndpoint: 172.16.0.10:6443
etcd:
  local:
    dataDir: /var/lib/etcd
imageRepository: registry.cn-hangzhou.aliyuncs.com/google_containers
kind: ClusterConfiguration
kubernetesVersion: v1.22.17
networking:
  dnsDomain: cluster.local
  serviceSubnet: 10.96.0.0/12
scheduler: {}
```

#### 重新生成证书 重启 kube-apiserver

```
mv /etc/kubernetes/pki/apiserver.{crt,key} ~
kubeadm init phase certs apiserver --config kubeadm.yaml
docker ps -a|grep kube-apiserver|awk '{print $1}'|xargs docker rm -f
```

#### 上传证书到集群

```
kubeadm init phase upload-certs --upload-certs --config kubeadm.yaml
```

#### 修改 kubelet.conf admin.conf controller-manager.conf scheduler.conf

#### manifests 需要修改吗 不需要吧？

```
sed -i "s/172.16.0.17/172.16.0.51/g" /etc/kubernetes/kubelet.conf
sed -i "s/172.16.0.17/172.16.0.51/g" /etc/kubernetes/admin.conf
sed -i "s/172.16.0.17/172.16.0.51/g" /etc/kubernetes/controller-manager.conf
sed -i "s/172.16.0.17/172.16.0.51/g" /etc/kubernetes/scheduler.conf
cp -a /etc/kubernetes/admin.conf ~/.kube/config
```

#### 重启 kubelet

```
systemctl restart kubelet
```

#### 查看集群状态

```
kubectl get nodes
```

#### kube-proxy 修改 server: https://172.16.0.51:6443 地址

```
kubectl -n kube-system patch cm kube-proxy --type merge --patch "$(kubectl get cm kube-proxy -n kube-system -o json | jq '.data["kubeconfig.conf"] |= (. | sub("server: https://.*:6443"; "server: https://172.16.0.51:6443"))')"


```

#### 添加 worker 节点

```
kubeadm join 172.16.0.10:6443 --token ex5ipw.mtjku8p1j61ezhxd --discovery-token-ca-cert-hash sha256:f431fd409cd8cd5e39d2a0236a823880d46561118fc54293f9d603f37ada6986
```

### 添加 master 节点

#### 上传 kubeadm-config 到集群

#### 更新集群 master 节点 获取证书 controlPlaneEndpoint

```
kubeadm init phase upload-config kubeadm --config kubeadm.yaml
docker ps |grep -E 'k8s_kube-apiserver|k8s_kube-controller-manager|k8s_kube-scheduler|k8s_etcd_etcd' | awk -F ' ' '{print $1}' |xargs docker restart

kubectl -n kube-public edit cm cluster-info
kubectl cluster-info
kubeadm init phase upload-certs --upload-certs --config kubeadm.yaml
```

####

```
kubeadm token create --print-join-command --config kubeadm.yaml
```

#### 添加 master --control-plane --certificate-key

```
kubeadm join 172.16.0.10:6443 --token ex5ipw.mtjku8p1j61ezhxd --discovery-token-ca-cert-hash sha256:f431fd409cd8cd5e39d2a0236a823880d46561118fc54293f9d603f37ada6986 --control-plane --certificate-key 8e63063036ef3cd2b0ff5486abc18ae228833dc91f6a2f137395420d809c4ca5
```

#### k8s etcd 查看

```
kubectl -n kube-system exec -it etcd-0 -- etcdctl member list --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key --endpoints=https://172.16.0.2:2379
```

#### endpoint health

```
kubectl -n kube-system exec -it etcd-0 -- etcdctl endpoint health --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key --endpoints=https://172.16.0.2:2379
```

#### endpoint status

```
kubectl -n kube-system exec -it etcd-master02 -- etcdctl endpoint status  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key --endpoints=https://172.16.0.3:2379,https://172.16.0.2:2379,https://172.16.0.4:2379
```
