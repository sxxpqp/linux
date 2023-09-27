#!/bash/bash
namespace=srs

cat <<EOF | kubectl -n $namespace apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-nas
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1000Gi
EOF


cat <<EOF | kubectl -n $namespace apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: srs-origin-config
data:
  srs.conf: |-
    listen              1935;
    max_connections     1000;
    daemon              off;
    http_api {
        enabled         on;
        listen          1985;
    }
    http_server {
        enabled         on;
        listen          8080;
    }
    
    vhost __defaultVhost__ {
        cluster {
            origin_cluster  on;
            coworkers       srs-origin-0.socs:1985 srs-origin-1.socs:1985 srs-origin-2.socs:1985;
        }
        http_remux {
            enabled     on;
        }
        hls {
            enabled         on;
        }
    }

---

apiVersion: v1
kind: Service
metadata:
  name: socs
spec:
  clusterIP: None
  selector:
    app: srs-origin
  ports:
  - name: socs-1935-1935
    port: 1935
    protocol: TCP
    targetPort: 1935

---

apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: srs-origin
  labels:
    app: srs-origin
spec:
  serviceName: "socs"
  replicas: 3
  selector:
    matchLabels:
      app: srs-origin
  template:
    metadata:
      labels:
        app: srs-origin
    spec:
      volumes:
      - name: cache-volume
        persistentVolumeClaim:
          claimName: pvc-nas
      - name: config-volume
        configMap:
          name: srs-origin-config
      containers:
      - name: srs
        image: ossrs/srs:3
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 1935
        - containerPort: 1985
        - containerPort: 8080
        volumeMounts:
        - name: cache-volume
          mountPath: /usr/local/srs/objs/nginx/html
          readOnly: false
        - name: config-volume
          mountPath: /usr/local/srs/conf

---

apiVersion: v1
kind: Service
metadata:
  name: srs-api-service
spec:
  type: LoadBalancer
  selector:
    statefulset.kubernetes.io/pod-name: srs-origin-0
  ports:
  - name: srs-api-service-1985-1985
    port: 1985
    protocol: TCP
    targetPort: 1985

EOF

cat <<EOF | kubectl -n $namespace apply -f -

apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-origin-deploy
  labels:
    app: nginx-origin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-origin
  template:
    metadata:
      labels:
        app: nginx-origin
    spec:
      volumes:
      - name: cache-volume
        persistentVolumeClaim:
          claimName: pvc-nas
      containers:
      - name: nginx
        image: nginx
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 80
        volumeMounts:
        - name: cache-volume
          mountPath: /usr/share/nginx/html
          readOnly: true
      - name: srs-cp-files
        image: ossrs/srs:3
        imagePullPolicy: IfNotPresent
        volumeMounts:
        - name: cache-volume
          mountPath: /tmp/html
          readOnly: false
        command: ["/bin/sh"]
        args:
        - "-c"
        - >
          if [[ ! -f /tmp/html/index.html ]]; then
            cp -R ./objs/nginx/html/* /tmp/html
          fi &&
          sleep infinity

---

apiVersion: v1
kind: Service
metadata:
  name: srs-http-service
spec:
  type: LoadBalancer
  selector:
    app: nginx-origin
  ports:
  - name: nginx-origin-service-80-80
    port: 80
    protocol: TCP
    targetPort: 80
EOF


cat <<EOF | kubectl -n $namespace apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: srs-edge-config
data:
  srs.conf: |-
    listen              1935;
    max_connections     1000;
    daemon              off;
    http_api {
        enabled         on;
        listen          1985;
    }
    http_server {
        enabled         on;
        listen          8080;
    }
    vhost __defaultVhost__ {
        cluster {
            mode            remote;
            origin          srs-origin-0.socs srs-origin-1.socs srs-origin-2.socs;
        }
        http_remux {
            enabled     on;
        }
    }

---

apiVersion: apps/v1
kind: Deployment
metadata:
  name: srs-edge-deploy
  labels:
    app: srs-edge
spec:
  replicas: 4
  selector:
    matchLabels:
      app: srs-edge
  template:
    metadata:
      labels:
        app: srs-edge
    spec:
      volumes:
      - name: config-volume
        configMap:
          name: srs-edge-config
      containers:
      - name: srs
        image: ossrs/srs:3
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 1935
        - containerPort: 1985
        - containerPort: 8080
        volumeMounts:
        - name: config-volume
          mountPath: /usr/local/srs/conf

---

apiVersion: v1
kind: Service
metadata:
  name: srs-edge-service
spec:
  type: LoadBalancer
  selector:
    app: srs-edge
  ports:
  - name: srs-edge-service-1935-1935
    port: 1935
    protocol: TCP
    targetPort: 1935
  - name: srs-edge-service-8080-8080
    port: 8080
    protocol: TCP
    targetPort: 8080
EOF