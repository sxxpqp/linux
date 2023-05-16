#tensorflow镜像构建，通过dockerfile实现
```
cat >Dockerfile<<EOF
FROM rocm/tensorflow:rocm4.1-tf2.4-dev
COPY requirements-gpu.txt .
#RUN python -m pip install --upgrade pip
RUN pip install -r requirements-gpu.txt  -i https://pypi.tuna.tsinghua.edu.cn/simple
EOF
```
#编辑 requirements-gpu.txt
```
cat >requirements-gpu.txt<<EOF
opencv-python==4.2.0.32
lxml
tqdm
seaborn
yolov3_tf2
```

#构建dockerfile镜像
```
docker build -t rocm/tensorflow:rocm4.1-tf2.4-pro .
```

#编辑tensorflow的工作负载tf-deploy.yaml
```
cat >tf-deploy.yaml<<EOF
kind: Deployment
apiVersion: apps/v1
metadata:
  name: tensorflowgpu-test-sf
  namespace: admin
  labels:
    app.kubernetes.io/instance: tensorflowgpu-ro-ym6i4h
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/name: tensorflowgpu-rocm
    app.kubernetes.io/version: rocm4.1-tf2.4-dev
    app.kubesphere.io/instance: tensorflowgpu-ro-ym6i4h
    helm.sh/chart: tensorflowgpu-rocm-0.5.0
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/instance: tensorflowgpu-test-sf
      app.kubernetes.io/name: tensorflowgpu-rocm
  template:
    metadata:
      creationTimestamp: null
      labels:
        app.kubernetes.io/instance: tensorflowgpu-test-sf
        app.kubernetes.io/name: tensorflowgpu-rocm
    spec:
      volumes:
        - name: tf3
          nfs:
            server: 10.12.1.96 #nfs共享存储地址
            path: /data/nfs/tf #nfs共享存储
      containers:
        - name: tensorflowgpu-rocm
          image: 'registry.cn-hangzhou.aliyuncs.com/sxxpqp/tensorflow:rocm4.1-tf2.4-pro'
          command:
            - /bin/sh
          args:
            - '-c'
            - while true; do echo hello; sleep 3600;done
          ports:
            - name: http
              containerPort: 22
              protocol: TCP
          resources:
            limits:
              amd.com/gpu: 4
          volumeMounts:
            - name: tf3
              mountPath: /tf/models
          terminationMessagePath: /dev/termination-log
          terminationMessagePolicy: File
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
            #nodeSelector:
            #gpu: node5      
      restartPolicy: Always
      terminationGracePeriodSeconds: 30
      dnsPolicy: ClusterFirst
      securityContext: {}
      schedulerName: default-scheduler
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 25%
      maxSurge: 25%
  revisionHistoryLimit: 10
  progressDeadlineSeconds: 600
EOF
```
##运行工作负载
```
kubectl apply -f tf-deploy.yaml
```
##查看
```
df -h
``` 
在宿主机上执行,查看10.12.1.96:/data/nfs/tf path,并加载yolov3-tf2模型
````
cd $path
git clone https://github.com/zzh8829/yolov3-tf2.git
cd yolov3-tf2
wget https://pjreddie.com/media/files/yolov3.weights -O data/yolov3.weights
python convert.py --weights ./data/yolov3.weights --output ./checkpoints/yolov3.tf

````