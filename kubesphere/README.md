## 关于kubesphere的日常总结及分享

### 多集群管理

#### kubesphere host集群配置文件

```
apiVersion: installer.kubesphere.io/v1alpha1
kind: ClusterConfiguration
metadata:
  labels:
    version: v3.1.1
  name: ks-installer
  namespace: kubesphere-system
spec:
  alerting:
    enabled: true
  auditing:
    enabled: true
  authentication:
    jwtSecret: ''
  common:
    es:
      basicAuth:
        enabled: false
        password: ''
        username: ''
      elasticsearchDataVolumeSize: 20Gi
      elasticsearchMasterVolumeSize: 4Gi
      elkPrefix: cl-svyozyxd
      externalElasticsearchPort: ''
      externalElasticsearchUrl: ''
      logMaxAge: 3
    minioVolumeSize: 20Gi
    monitoring:
      endpoint: 'http://prometheus-operated.kubesphere-monitoring-system.svc:9090'
    openldap:
      enabled: true
    openldapVolumeSize: 2Gi
    redis:
      enabled: true
    redisVolumSize: 2Gi
  console:
    enableMultiLogin: true
    port: 30880
  devops:
    enabled: true
    jenkinsJavaOpts_MaxRAM: 2g
    jenkinsJavaOpts_Xms: 512m
    jenkinsJavaOpts_Xmx: 512m
    jenkinsMemoryLim: 2Gi
    jenkinsMemoryReq: 1500Mi
    jenkinsVolumeSize: 8Gi
  etcd:
    endpointIps: '192.168.0.3,192.168.0.6,192.168.0.7'
    monitoring: true
    port: 2379
    tlsEnable: false
  events:
    enabled: true
    ruler:
      enabled: true
      replicas: 2
  ks_image_pull_policy: IfNotPresent
  kubeedge:
    cloudCore:
      cloudHub:
        advertiseAddress:
          - 139.198.122.166
        nodeLimit: '100'
      cloudhubHttpsPort: '10002'
      cloudhubPort: '10000'
      cloudhubQuicPort: '10001'
      cloudstreamPort: '10003'
      nodeSelector:
        node-role.kubernetes.io/worker: ''
      service:
        cloudhubHttpsNodePort: '30002'
        cloudhubNodePort: '30000'
        cloudhubQuicNodePort: '30001'
        cloudstreamNodePort: '30003'
        tunnelNodePort: '30004'
      tolerations: []
      tunnelPort: '10004'
    edgeWatcher:
      edgeWatcherAgent:
        nodeSelector:
          node-role.kubernetes.io/worker: ''
        tolerations: []
      nodeSelector:
        node-role.kubernetes.io/worker: ''
      tolerations: []
    enabled: true
  local_registry: ''
  logging:
    enabled: true
    logsidecar:
      enabled: true
      replicas: 2
  metrics_server:
    enabled: true
  monitoring:
    prometheusMemoryRequest: 400Mi
    prometheusVolumeSize: 20Gi
    storageClass: ''
  multicluster:
    clusterRole: host
    proxyPublishAddress: 'http://139.198.122.166:32715'
  network:
    ippool:
      type: none
    networkpolicy:
      enabled: true
    topology:
      type: none
  openpitrix:
    store:
      enabled: true
  openpitrix_job_repo: kubesphere/openpitrix-jobs
  persistence:
    storageClass: ''
  servicemesh:
    enabled: true

```

#### 获取主集群的jwtSecret

```
kubectl -n kubesphere-system get cm kubesphere-config -o yaml | grep -v "apiVersion" | grep jwtSecret
```

#### 成员集群添加步骤

修改ks-installer配置文件

```
kubectl edit cc ks-installer -n kubesphere-system
```

在 `ks-installer` 的 YAML 文件中对应输入上面所示的 `jwtSecret`：

```
authentication:
  jwtSecret: 4rdisUzp50XpeklFMBhH0We6rBTXD8dX
```

向下滚动并将 `clusterRole` 的值设置为 `member`，然后点击**确定**（如果使用 Web 控制台）使其生效：

```
multicluster:
  clusterRole: member
```

## 部署node-exporter**

```
docker run -d  --restart=always --name node -p 9100:9100   -v /proc:/host/proc:ro   -v /sys:/host/sys:ro   -v /:/rootfs:ro   -v /etc/localtime:/etc/localtime -v /etc/timezone:/etc/timezone   --net="host"   prom/node-exporter
```

## k8s集群开启ipvs模式
1.2kube-proxy开启ipvs的前置条件
 由于ipvs已经加入到了内核的主干，所以为kube-proxy开启ipvs的前提需要加载以下的内核模块：
 ip_vs
 ip_vs_rr
 ip_vs_wrr
 ip_vs_sh
 nf_conntrack_ipv4

在所有的Kubernetes节点node1和node2上执行以下脚本:
```
 cat > /etc/sysconfig/modules/ipvs.modules <<EOF
 #!/bin/bash
 modprobe  ip_vs
 modprobe  ip_vs_rr
 modprobe  ip_vs_wrr
 modprobe  ip_vs_sh
 modprobe  nf_conntrack_ipv4
 EOF
 ```
 ```
 chmod 755 /etc/sysconfig/modules/ipvs.modules && bash /etc/sysconfig/modules/ipvs.modules && lsmod | grep -e ip_vs -e nf_conntrack_ipv4
 ```
 脚本创建了的/etc/sysconfig/modules/ipvs.modules文件，保证在节点重启后能自动加载所需模块。 使用lsmod | grep -e ip_vs -e nf_conntrack_ipv4命令查看是否已经正确加载所需的内核模块。
 在所有节点上安装ipset软件包
 ```
 yum install ipset -y
 ```
 为了方便查看ipvs规则我们要安装ipvsadm(可选)
 ```
 yum install ipvsadm -y
 ```
#修改ConfigMap的kube-system/kube-proxy中的config.conf，把 mode: “” 改为mode: “ipvs” 保存退出即可