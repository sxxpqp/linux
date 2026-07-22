helm repo add kubeblocks https://apecloud.github.io/helm-charts
helm repo update

# 装 RocketMQ addon

helm upgrade -i kb-addon-rocketmq kubeblocks/rocketmq 
  --namespace kb-system


apiVersion: apps.kubeblocks.io/v1
kind: Cluster
metadata:
  name: rocketmq-cluster
  namespace: demo
spec:
  clusterDef: rocketmq
  topology: master-slave
  terminationPolicy: Delete
  componentSpecs:
    - name: namesrv
      replicas: 1
      serviceVersion: 4.9.6
      resources:
        limits:
          cpu: "1"
          memory: "1Gi"
        requests:
          cpu: "0.5"
          memory: "1Gi"
    - name: exporter
      replicas: 1
      serviceVersion: 0.0.3
      resources:
        limits:
          cpu: "0.5"
          memory: "512Mi"
        requests:
          cpu: "0.1"
          memory: "512Mi"
    - name: dashboard
      replicas: 1
      serviceVersion: 2.0.1
      resources:
        limits:
          cpu: "0.5"
          memory: "512Mi"
        requests:
          cpu: "0.1"
          memory: "512Mi"
  shardings:
    - name: broker
      shards: 1          # number of broker groups
      template:
        name: rocketmq-broker
        replicas: 1      # 1 = master only; 2 = master + 1 slave
        serviceVersion: 4.9.6
        resources:
          limits:
            cpu: "1"
            memory: "2Gi"
          requests:
            cpu: "0.5"
            memory: "1Gi"
        volumeClaimTemplates:
          - name: data
            spec:
              accessModes:
                - ReadWriteOnce
              resources:
                requests:
                  storage: 10Gi
