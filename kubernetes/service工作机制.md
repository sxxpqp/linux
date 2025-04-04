---
### 八种服务类型 

##### 1. ClusterIP：默认类型，只能在集群内部访问，通过集群内部的IP地址访问
##### 2. NodePort：通过集群内部的IP地址和端口访问
##### 3. LoadBalancer：通过云服务商提供的负载均衡器访问
##### 4. ExternalName：通过CNAME记录访问
##### 5. Headless：不创建ClusterIP，只创建Endpoints
##### 6. ExternalIPs：通过外部IP访问
##### 7. hostPort：通过宿主机IP和端口访问 通过iptables转发到pod 
##### 8. hostNetwork：通过宿主机IP和端口访问 通过修改pod的网络命名空间，让pod的网络命名空间和宿主机共享，让pod的网络直接使用宿主机的网络，pod的ip地址就是宿主机的ip地址。
#### ClusterIP创建服务 通过selector选择器创建服务，通过label标签选择器选择pod,并创建endpoint。
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
    selector:  #通过label标签选择器选择pod,并创建endpoint
        app: nginx
    ports:
    - protocol: TCP
      port: 80
      targetPort: 80
```

#### ClusterIP创建服务 通过endpoints指定服务的endpoint
```
apiVersion: v1
kind: Endpoints
metadata:
  name: my-service-manual-endpoints
subsets:
  - addresses:
      - ip: 192.168.1.54 #手动指定endpoint的ip地址可以是pod的ip地址，也可以是宿主机的ip地址或者外部ip地址
    ports:
      - name: http #指定端口名称跟service的端口名称一致
        port: 80
        protocol: TCP
```
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service-manual-endpoints
spec:
    ports:
    - protocol: TCP
      port: 80
      name: http #指定端口名称跟service的端口名称一致
```
#### nodePort创建服务 LoadBalancer创建服务
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service-nodeport
spec:
    type: NodePort #指定服务类型为NodePort、LoadBalancer、ClusterIP
    ports:
    - protocol: TCP
      port: 80
      targetPort: 80
      nodePort: 30080  
```
#### ExternalName创建服务 通过CNAME记录访问
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service-externalname
spec:
    type: ExternalName #指定服务类型为ExternalName
    externalName: www.baidu.com
    ports:
    - port: 443
      targetPort: 443
```
#### Headless创建服务 不创建ClusterIP，只创建Endpoints
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service-headless
spec:
    clusterIP: None #指定服务类型为Headless
    ports:
    - protocol: TCP
      port: 80
      targetPort: 80
    selector:
        app: nginx    
```
#### ExternalIPs创建服务 通过外部IP访问
```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service-exrernalips
spec:
    externalIPs:
    - 192.168.1.100 #指定外部IP 就是宿主机IP,创建kube-ipvs0网卡.
    ports:
    - protocol: TCP
      port: 80
      targetPort: 80
    selector:
        app: nginx    
```
#### hostPort创建服务 通过宿主机IP和端口访问
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 2 #副本不可以大于宿主机端口的数量
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.7.9
        ports:
        - containerPort: 80
          name: ngpt
          hostPort: 31200
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi   
```
#### hostNetwork创建deployment
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 2 #副本不可以大于宿主机端口的数量
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      dnsPolicy: ClusterFirstWithHostNet #指定dnsPolicy为ClusterFirstWithHostNet，clusterFirstWithHostNet表示使用宿主机的dns，clusterFirst表示先使用k8s的dns.
      hostNetwork: true #指定hostNetwork为true，通过宿主机IP访问 80端口可以访问到pod的80端口 使用hostNetwork时，pod的ip地址就是宿主机的ip地址。 
      containers:
      - name: nginx
        image: nginx:1.7.9
        ports:
        - containerPort: 80
          name: ngpt
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi 
```
#### hostNetwork创建daemonset 
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nginx-daemonset
spec:
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      dnsPolicy: ClusterFirstWithHostNet #指定dnsPolicy为ClusterFirstWithHostNet，clusterFirstWithHostNet表示使用宿主机的dns，clusterFirst表示先使用k8s的dns.
      hostNetwork: true #指定hostNetwork为true，通过宿主机IP访问 80端口可以访问到pod的80端口 使用hostNetwork时，pod的ip地址就是宿主机的ip地址。 
      containers:
      - name: nginx
        image: nginx:1.7.9
        ports:
        - containerPort: 80
          name: ngpt
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi 
```
#### hostNetwork创建statefulset
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: nginx-statefulset
spec:
  serviceName: nginx-service-headless #指定服务名称 
  replicas: 1 #副本不可以大于宿主机端口的数量
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      dnsPolicy: ClusterFirstWithHostNet #指定dnsPolicy为ClusterFirstWithHostNet，clusterFirstWithHostNet表示使用宿主机的dns，clusterFirst表示先使用k8s的dns.
      hostNetwork: true #指定hostNetwork为true，通过宿主机IP访问 80端口可以访问到pod的80端口 使用hostNetwork时，pod的ip地址就是宿主机的ip地址。 
      containers:
      - name: nginx
        image: nginx:1.7.9
        ports:
        - containerPort: 80
          name: ngpt
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 256Mi 
```
