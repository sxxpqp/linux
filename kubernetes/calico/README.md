# Calico CNI

Calico 网络插件部署与配置。

## 子目录 / 文件说明

| 路径 | 状态 | 说明 |
|---|---|---|
| [onpremises/](onpremises/) | ✅ | **BPF 模式(推荐)**: Operator + Manifest 两套脚本, eBPF + 替换 kube-proxy |
| [bgp/](bgp/) | ✅ | **BGP 模式**: 跟路由器 peer, BIRD 直连路由, 不封包, 需要 kube-proxy |
| [test-connectivity.sh](test-connectivity.sh) | ✅ | **连通性验证**: Pod↔Pod / ClusterIP / DNS / 外网 |
| [switch-to-bgp.sh](switch-to-bgp.sh) | 参考 | BPF→BGP 迁移脚本(eBPF 切 Iptables + 恢复 kube-proxy + 开 BGP) |
| [calico-v3.25.yaml](calico-v3.25.yaml) | 历史归档 | Calico v3.25 完整部署 YAML |
| [calico-v3.25inter.yaml](calico-v3.25inter.yaml) | 历史归档 | Calico v3.25 互联部署配置 |
| [calico-v3.25-ens33.yaml](calico-v3.25-ens33.yaml) | 历史归档 | Calico v3.25(指定 ens33 网卡) |
| [calico.yaml](calico.yaml) | 历史归档 | Calico 完整部署 YAML |
