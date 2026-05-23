# Calico CNI

Calico 网络插件部署与配置。

## 文件说明

| 文件 | 说明 |
|---|---|
| [calico-v3.25.yaml](calico-v3.25.yaml) | Calico v3.25 完整部署 YAML |
| [calico-v3.25inter.yaml](calico-v3.25inter.yaml) | Calico v3.25 互联部署配置 |
| [calico.yaml](calico.yaml) | Calico 完整部署 YAML |
| [switch-to-bgp.sh](switch-to-bgp.sh) | Calico BGP 模式切换命令：kubectl edit ippools 修改默认 IP 池、calicoctl get bgpconfiguration 查看 BGP 配置 |
