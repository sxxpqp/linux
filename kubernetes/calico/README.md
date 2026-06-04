# Calico CNI

Calico 网络插件部署与配置。

## 子目录 / 文件说明

| 路径 | 状态 | 说明 |
|---|---|---|
| [onpremises/](onpremises/) | ✅ 生产验证 | **新装推荐**: Operator + Manifest 两套脚本, eBPF + 替换 kube-proxy, 交叉安装/卸载已验证 |
| [test-connectivity.sh](test-connectivity.sh) | ✅ | **连通性验证**: Pod↔Pod / ClusterIP / DNS / 外网, 安装后跑一次确认网络正常 |
| [calico-v3.25.yaml](calico-v3.25.yaml) | 历史归档 | Calico v3.25 完整部署 YAML |
| [calico-v3.25inter.yaml](calico-v3.25inter.yaml) | 历史归档 | Calico v3.25 互联部署配置 |
| [calico-v3.25-ens33.yaml](calico-v3.25-ens33.yaml) | 历史归档 | Calico v3.25(指定 ens33 网卡) |
| [calico.yaml](calico.yaml) | 历史归档 | Calico 完整部署 YAML |
| [switch-to-bgp.sh](switch-to-bgp.sh) | 参考 | BGP 模式切换命令片段(`kubectl edit ippools` / `calicoctl get bgpconfiguration`) |
