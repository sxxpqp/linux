### 安装openelb控制器
```
kubectl apply -f https://raw.githubusercontent.com/openelb/openelb/master/deploy/openelb.yaml
```
### 查看openelb控制器
```
kubectl get po -n openelb-system
```
### 创建openelb

```
cat>openelb.yaml<<EOF
apiVersion: network.kubesphere.io/v1alpha2
kind: Eip
metadata:
  name: layer2-eip
spec:
  address: 192.168.0.91-192.168.0.100
  interface: eth0
  protocol: layer2
EOF
```
``` 
kubectl apply -f openelb.yaml
```
在svc中开启openelb 添加注解
```
  annotations:
    lb.kubesphere.io/v1alpha1: openelb
    protocol.openelb.kubesphere.io/v1alpha1: layer2
    eip.openelb.kubesphere.io/v1alpha2: layer2-eip

```