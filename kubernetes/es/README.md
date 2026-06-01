# Elasticsearch

通用 Elasticsearch 部署模板,**走 ECK operator**(`elasticsearch.k8s.elastic.co/v1` CRD)。

## 跟 turingcloud-elasticsearch/ 的区别

| 目录 | 部署方式 | 用途 |
|---|---|---|
| **es/**(本目录) | ECK operator CRD (`kind: Elasticsearch`) | 通用模板,quickstart 实例,默认 ns |
| [turingcloud-elasticsearch/](../turingcloud-elasticsearch/) | 裸 StatefulSet (`sts.yaml`) | TuringCloud 业务专用,定制副本/资源 |

新建业务集群优先用 **ECK 这套**,operator 管理 cert/upgrade/rolling 更省心;手写 StatefulSet 那套只在 turingcloud 业务延用,**不推荐再用**。

## 文件说明

| 文件 | 说明 |
|---|---|
| [crddeploy.yaml](crddeploy.yaml) | Elasticsearch CRD 部署:基于 elasticsearch.k8s.elastic.co/v1,default 命名空间,quickstart 实例 |
