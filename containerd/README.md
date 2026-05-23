# Containerd 容器运行时

Containerd 安装、离线部署、K8s 集成配置。

## 文件说明

| 文件 | 说明 |
|---|---|
| [containerd-install.sh](containerd-install.sh) | 自动化安装脚本：从文件服务器下载 containerd 1.7.18 + CNI plugins 1.5.1 压缩包，解压并创建 systemd 服务；修改 config.toml 配置 SystemdCgroup=true、sandbox_image 镜像仓库镜像为阿里云、Docker 加速器；配置内核参数 br_netfilter 和 ip_forward；下载并替换 runc 二进制 |
| [containerd-offline-install.md](containerd-offline-install.md) | 离线安装指南：CNI 插件解压、containerd CRI 解压安装、创建 systemd 服务单元、config.toml 配置修改（systemd cgroup driver、pause 镜像、docker hub mirror） |
