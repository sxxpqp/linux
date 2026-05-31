# nvidia/ — 历史归档(chfs 副本方式 + RHEL 支持)

NVIDIA Container Toolkit 的**老一代安装方式**:把 nvidia 官方 gpgkey / list / repo 文件**预先放到 chfs**,客户端 curl chfs 副本。

## 跟 `../nvidia-container-toolkit/` 的关系

| 维度 | 本目录 (nvidia/) | [nvidia-container-toolkit/](../nvidia-container-toolkit/) |
|---|---|---|
| 上游访问方式 | 把上游文件 mirror 到 **chfs.sxxpqp.top**,客户端拉副本 | 走 **Nexus raw-nvidia proxy**,透传 nvidia.github.io |
| OS 覆盖 | apt(Ubuntu/Debian) + **yum(RHEL/CentOS)** | 只 apt |
| 主线状态 | 🟡 历史归档,文件留下来作参考 | 🟢 主线推荐 |

**新装机器优先用 `../nvidia-container-toolkit/install.sh`**(Ubuntu/Debian),如果是 RHEL/CentOS 节点,用本目录的 `nvidia-container-toolkit.repo`。

## 文件说明

| 文件 | 用途 |
|---|---|
| `install.sh` | 旧版安装脚本(走 chfs 副本) |
| `install.md` | 同上的命令片段 |
| `gpgkey` | nvidia 官方 PGP 公钥(chfs 已有副本) |
| `nvidia-container-toolkit.list` | apt 源(Ubuntu/Debian) |
| `nvidia-container-toolkit.repo` | yum 源(RHEL/CentOS) — **新版没覆盖,要装 RHEL 节点看这里** |
| `nvidia-docker.md` | nvidia-ctk runtime configure 笔记(配 docker / containerd 用 nvidia runtime) |
| `nvidia-docker.sh` | nvidia-docker 老脚本 |
| `download-offline-packages.sh` | `apt-get download` 把 nvidia-container-toolkit 全套依赖打包到本地,**离线节点部署用** |

## 离线节点流程

1. 在能联网的机器上跑 `download-offline-packages.sh`,得到一堆 `.deb` 在 `nvidia-packages/`
2. 打包整个目录 scp 到离线节点
3. 离线节点上 `cd nvidia-packages && sudo dpkg -i *.deb`
