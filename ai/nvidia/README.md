# nvidia/ — 驱动/CUDA/容器 toolkit 安装

## 文件说明

| 文件 | 用途 | 状态 |
|---|---|---|
| `ubuntu-nvidia-bin.sh` | **Ubuntu 驱动 + CUDA 二进制安装(.run 方式)**,含开源/闭源内核模块选择 + 驱动↔CUDA 版本对齐校验,离线支持 `--local-*` | 🟢 主线推荐 |
| `nvidia-driver-install.sh` | 驱动 apt/elrepo 方式(Ubuntu + CentOS),无 CUDA | 🟡 历史参考 |

## ubuntu-nvidia-bin.sh(主线)

- **驱动**:`NVIDIA-Linux-x86_64-<ver>.run`(`us.download.nvidia.com`,`--kernel-open` 开源模块 / 默认闭源,`--dkms` 自动重编)
- **CUDA**:`cuda_<ver>_linux.run`(`developer.download.nvidia.com`,只装 toolkit 不带驱动,不覆盖 libGL)
- **toolkit**:apt 走 Nexus raw-nvidia(官方无 .run 包)
- **版本对齐**:内置 CUDA→最低驱动校验表(12.0→525.60.13 … 13.0→580.65.06),不满足直接报错
- **离线**:`--local-driver` / `--local-cuda` 指定 chfs 预下载的 .run 文件

## nvidia-container-toolkit(配套)

| 维度 | [nvidia-container-toolkit/](../nvidia-container-toolkit/) |
|---|---|
| 上游访问方式 | 走 **Nexus raw-nvidia proxy**,透传 nvidia.github.io |
| OS 覆盖 | 只 apt(Ubuntu/Debian) |

---

# 历史归档(chfs 副本方式 + RHEL 支持)

NVIDIA Container Toolkit 的**老一代安装方式**:把 nvidia 官方 gpgkey / list / repo 文件**预先放到 chfs**,客户端 curl chfs 副本。

## 跟 `../nvidia-container-toolkit/` 的关系

| 维度 | 本目录老文件 (nvidia/) | [nvidia-container-toolkit/](../nvidia-container-toolkit/) |
|---|---|---|
| 上游访问方式 | 把上游文件 mirror 到 **chfs.sxxpqp.top**,客户端拉副本 | 走 **Nexus raw-nvidia proxy**,透传 nvidia.github.io |
| OS 覆盖 | apt(Ubuntu/Debian) + **yum(RHEL/CentOS)** | 只 apt |
| 主线状态 | 🟡 历史归档,文件留下来作参考 | 🟢 主线推荐 |

**新装机器优先用 `ubuntu-nvidia-bin.sh`**(驱动+CUDA 一体),RHEL/CentOS 节点装 toolkit 用本目录的 `nvidia-container-toolkit.repo`。

## 其余文件说明

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
