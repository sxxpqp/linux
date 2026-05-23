# Ubuntu 系统配置

Ubuntu 系统基础配置与镜像加速。

## 说明

| 内容 | 说明 |
|---|---|
| APT 镜像源 | 替换为清华 Tuna 镜像源，适用 Ubuntu 14.04~22.04 |

## 一键替换 APT 源

```bash
# 替换 archive.ubuntu.com
sudo sed -i "s@http://.*archive.ubuntu.com@https://mirrors.tuna.tsinghua.edu.cn@g" /etc/apt/sources.list

# 替换 security.ubuntu.com
sudo sed -i "s@http://.*security.ubuntu.com@https://mirrors.tuna.tsinghua.edu.cn@g" /etc/apt/sources.list
```
