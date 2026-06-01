# nvidia-container-toolkit/ — apt + Nexus 主线版

新一代 NVIDIA Container Toolkit 安装,**apt 源走 Nexus raw-nvidia proxy** 代理 `nvidia.github.io`,gpgkey + list 透传,客户端不再依赖 chfs 副本。

> Nexus 前置(需要在 Nexus 后台建一次,所有节点共享): 仓库类型 `raw (proxy)`,Name `raw-nvidia`,Remote `https://nvidia.github.io/`。

## 跟 [../nvidia/](../nvidia/) 的关系

| 维度 | 本目录 | [../nvidia/](../nvidia/) |
|---|---|---|
| 上游访问方式 | Nexus raw 代理透传 | chfs 静态副本 |
| OS 覆盖 | **apt only**(Ubuntu/Debian) | apt + yum(RHEL/CentOS) |
| 主线状态 | 🟢 推荐 | 🟡 历史归档,留 RHEL repo 参考 |

**RHEL/CentOS 节点用 ../nvidia/ 那边的 `.repo` + yum 装**,本脚本只覆盖 Ubuntu/Debian。

## 用法

```bash
sudo bash install.sh                          # 装 + 不配 runtime
sudo bash install.sh --runtime containerd     # 装 + 自动 nvidia-ctk runtime configure containerd
sudo bash install.sh --runtime docker         # 装 + docker
sudo bash install.sh --no-install             # 只写 apt 源, 不跑 apt install (CI/调试)
sudo bash install.sh --nexus '<url>'          # 覆盖 Nexus 地址
```

## 后置: K8s 节点

装完 toolkit + 配好 runtime 后,集群里还要装 device plugin:

```bash
kubectl apply -f kubernetes/kube-device-plugin/nvidia-device-plugin.yml
```

## 验证

```bash
nvidia-ctk --version
nvidia-smi
# 用 containerd 跑 cuda 容器
sudo ctr image pull docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04
sudo ctr run --rm --gpus 0 docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04 test nvidia-smi
```
