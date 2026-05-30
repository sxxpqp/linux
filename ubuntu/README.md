# Ubuntu 系统配置

Ubuntu 系统基础配置与镜像加速。源:阿里云 (`https://mirrors.aliyun.com/ubuntu/`)。

参考:<https://developer.aliyun.com/mirror/ubuntu/>

## 版本对照表

| Ubuntu 版本 | Codename | 源文件位置 |
|---|---|---|
| 14.04 | trusty | `/etc/apt/sources.list` |
| 16.04 | xenial | `/etc/apt/sources.list` |
| 18.04 | bionic | `/etc/apt/sources.list` |
| 20.04 | focal | `/etc/apt/sources.list` |
| 22.04 | jammy | `/etc/apt/sources.list` |
| 23.04 | lunar | `/etc/apt/sources.list` |
| **24.04** | **noble** | `/etc/apt/sources.list.d/ubuntu.sources` (DEB822) |
| 25.10 | resolute | `/etc/apt/sources.list.d/ubuntu.sources` (DEB822) |

---

## 方法 A:sed 一键替换(快,适合已用机)

### 22.04 及以下(老格式 `sources.list`)

```bash
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
sudo sed -i "s@http://.*archive.ubuntu.com@https://mirrors.aliyun.com@g" /etc/apt/sources.list
sudo sed -i "s@http://.*security.ubuntu.com@https://mirrors.aliyun.com@g" /etc/apt/sources.list
sudo apt update
```

### 24.04+(新格式 `ubuntu.sources`,DEB822)

```bash
sudo cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak
sudo sed -i -E "s@https?://[a-z.]*archive\.ubuntu\.com@https://mirrors.aliyun.com@g" /etc/apt/sources.list.d/ubuntu.sources
sudo sed -i -E "s@https?://[a-z.]*security\.ubuntu\.com@https://mirrors.aliyun.com@g" /etc/apt/sources.list.d/ubuntu.sources
sudo apt update
```

---

## 方法 B:完整覆盖(稳,适合新装机,阿里云官方推荐)

### 22.04 (jammy) — 老格式

```bash
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak

sudo tee /etc/apt/sources.list > /dev/null <<'EOF'
deb https://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse
# deb https://mirrors.aliyun.com/ubuntu/ jammy-proposed main restricted universe multiverse
EOF

sudo apt update
```

> 换其它老版本就把 `jammy` 替换成 `focal` / `bionic` / `xenial` / `trusty` 即可。

### 24.04 (noble) — DEB822 新格式

```bash
sudo cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak

sudo tee /etc/apt/sources.list.d/ubuntu.sources > /dev/null <<'EOF'
Types: deb
URIs: https://mirrors.aliyun.com/ubuntu
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: https://mirrors.aliyun.com/ubuntu
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF

sudo apt update
```

> 25.10 (resolute) 把 `noble` 替换成 `resolute` 即可。

---

## 阿里云 ECS 内部加速(可选)

如果机器是**阿里云 ECS**,把 `mirrors.aliyun.com` 替换成 `mirrors.cloud.aliyuncs.com` 走内网,**免流量、更快**:

```bash
sudo sed -i 's|https://mirrors.aliyun.com|http://mirrors.cloud.aliyuncs.com|g' /etc/apt/sources.list
# 或对 24.04+
sudo sed -i 's|https://mirrors.aliyun.com|http://mirrors.cloud.aliyuncs.com|g' /etc/apt/sources.list.d/ubuntu.sources
```

非阿里云机器跳过这步。

---

## 回滚

```bash
# 22.04 及以下
sudo mv /etc/apt/sources.list.bak /etc/apt/sources.list

# 24.04+
sudo mv /etc/apt/sources.list.d/ubuntu.sources.bak /etc/apt/sources.list.d/ubuntu.sources

sudo apt update
```
