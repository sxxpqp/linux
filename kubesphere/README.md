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

