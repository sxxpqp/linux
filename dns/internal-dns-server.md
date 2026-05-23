如果你有多个内网，并希望 自己搭建 DNS 服务器 来为这些内网提供域名解析服务，同时为它们设置上游 DNS 服务器（例如 183.62.243.147），可以按以下步骤进行配置。以下是如何在 Ubuntu 上使用 BIND9 配置多个内网的 DNS 服务，并进行域名解析的详细步骤。

1. 安装 BIND9 DNS 服务器
首先，你需要在 Ubuntu 上安装 BIND9：

```
sudo apt update
sudo apt install bind9 bind9utils bind9-doc dnsutils
```
2. 配置上游 DNS 服务器
编辑 BIND9 的配置文件 /etc/bind/named.conf.options，并添加你上游的 DNS 服务器（如 183.62.243.147）。

```
sudo nano /etc/bind/named.conf.options
```
添加以下配置：

```
options {
    directory "/var/cache/bind";

    // 上游 DNS 服务器
    forwarders {
        183.62.243.147;
        8.8.8.8;  // 备用 DNS
    };

    allow-query { any; };

    // 启用 DNS 缓存
    dnssec-validation auto;

    listen-on { any; };
    listen-on-v6 { any; };
};
```
这段配置将 183.62.243.147 设置为首选上游 DNS 服务器，8.8.8.8 作为备用 DNS。

3. 为多个内网设置 DNS 解析（虚拟域名）
为了支持多个内网的域名解析，你需要为每个内网配置独立的 DNS 区域。假设你有多个内网域名，例如 lan1.local、lan2.local 等，且它们的域名解析与外网不同，你可以按照以下步骤进行配置。

3.1 配置多个内网的 DNS 区域
在 named.conf.local 文件中配置多个内网的域名解析区域：

```
sudo nano /etc/bind/named.conf.local
```
添加如下内容：

```
// 内网 1 的 DNS 配置
zone "lan1.local" {
    type master;
    file "/etc/bind/db.lan1.local";
};

// 内网 2 的 DNS 配置
zone "lan2.local" {
    type master;
    file "/etc/bind/db.lan2.local";
};
```
// 你可以根据需要添加更多内网区域
3.2 创建内网的区域数据文件
每个内网区域都需要一个数据文件，用来存储该内网的域名解析记录。

首先，复制一个现有的文件作为模板：

```
sudo cp /etc/bind/db.local /etc/bind/db.lan1.local
sudo cp /etc/bind/db.local /etc/bind/db.lan2.local
```
3.3 编辑区域数据文件
例如，编辑 db.lan1.local 文件，定义你内网的域名和 IP 映射。

```
sudo nano /etc/bind/db.lan1.local
```
修改文件内容：

```
$TTL    604800
@       IN      SOA     ns1.lan1.local. admin.lan1.local. (
                      2021011001 ; Serial
                      604800     ; Refresh
                      86400      ; Retry
                      2419200    ; Expire
                      604800 )   ; Minimum TTL

@       IN      NS      ns1.lan1.local.

ns1     IN      A       192.168.1.1   ; 内网 DNS 服务器的 IP

// 添加内网的其他主机记录
host1   IN      A       192.168.1.2
host2   IN      A       192.168.1.3
```
对于 lan2.local，按类似的方式编辑：

```
sudo nano /etc/bind/db.lan2.local
```
```
$TTL    604800
@       IN      SOA     ns1.lan2.local. admin.lan2.local. (
                      2021011001 ; Serial
                      604800     ; Refresh
                      86400      ; Retry
                      2419200    ; Expire
                      604800 )   ; Minimum TTL

@       IN      NS      ns1.lan2.local.

ns1     IN      A       192.168.2.1   ; 内网 DNS 服务器的 IP

// 添加内网的其他主机记录
host1   IN      A       192.168.2.2
host2   IN      A       192.168.2.3
```
3.4 配置反向 DNS（可选）
如果你希望内网支持反向 DNS 查找（例如将 IP 地址反向解析为主机名），你需要配置反向 DNS 区域。假设 lan1 网络使用的是 192.168.1.0/24 子网，lan2 使用的是 192.168.2.0/24，你可以按以下方式配置。

在 /etc/bind/named.conf.local 中添加：

```
zone "1.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.192.168.1";
};

zone "2.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.192.168.2";
};
```
然后，分别创建和编辑反向区域数据文件 db.192.168.1 和 db.192.168.2。

4. 检查 BIND 配置
配置完成后，可以通过以下命令检查 BIND9 配置是否有错误：

```
sudo named-checkconf
sudo named-checkzone lan1.local /etc/bind/db.lan1.local
sudo named-checkzone lan2.local /etc/bind/db.lan2.local
```
5. 重启 BIND9 服务
如果一切配置正确，重启 BIND9 服务使更改生效：

```
sudo systemctl restart bind9
```
6. 配置防火墙（如果需要）
如果你的服务器启用了防火墙，确保允许 DNS 流量通过。默认的 DNS 端口是 53，你可以允许 UDP 和 TCP 端口 53：

```
sudo ufw allow 53
```
7. 测试 DNS 服务
可以通过 dig 或 nslookup 测试你的 DNS 服务器是否正常工作：

```
dig @localhost lan1.local
```

```
nslookup lan1.local 127.0.0.1
```