# 自建内网 DNS 服务器(BIND9)

> 源: https://github.com/sxxpqp/linux/blob/main/dns/internal-dns-server.md
> 状态: 验证过

为多个内网提供域名解析,同时设置上游 DNS(如 `183.62.243.147`)做转发。基于 Ubuntu + BIND9。

## 1. 安装 BIND9

```bash
sudo apt update
sudo apt install bind9 bind9utils bind9-doc dnsutils
```

## 2. 配置上游 DNS

编辑 `/etc/bind/named.conf.options`:

```bash
sudo nano /etc/bind/named.conf.options
```

```conf
options {
    directory "/var/cache/bind";

    // 上游 DNS 服务器
    forwarders {
        183.62.243.147;
        8.8.8.8;        // 备用 DNS
    };

    allow-query { any; };

    // 启用 DNS 缓存
    dnssec-validation auto;

    listen-on { any; };
    listen-on-v6 { any; };
};
```

`183.62.243.147` 是首选上游,`8.8.8.8` 是备用。

## 3. 为多个内网设置 DNS 解析(虚拟域名)

假设你有 `lan1.local`、`lan2.local` 两个内网域名,每个内网独立 zone。

### 3.1 配置多内网 zone

编辑 `/etc/bind/named.conf.local`:

```bash
sudo nano /etc/bind/named.conf.local
```

```conf
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

// 按需添加更多内网区域
```

### 3.2 创建区域数据文件

每个 zone 需要一个数据文件。先从模板复制:

```bash
sudo cp /etc/bind/db.local /etc/bind/db.lan1.local
sudo cp /etc/bind/db.local /etc/bind/db.lan2.local
```

### 3.3 编辑区域数据文件

`/etc/bind/db.lan1.local`:

```bash
sudo nano /etc/bind/db.lan1.local
```

```dns
$TTL    604800
@       IN      SOA     ns1.lan1.local. admin.lan1.local. (
                      2021011001 ; Serial
                      604800     ; Refresh
                      86400      ; Retry
                      2419200    ; Expire
                      604800 )   ; Minimum TTL

@       IN      NS      ns1.lan1.local.

ns1     IN      A       192.168.1.1   ; 内网 DNS 服务器的 IP

; 内网其他主机记录
host1   IN      A       192.168.1.2
host2   IN      A       192.168.1.3
```

`/etc/bind/db.lan2.local` 类似:

```dns
$TTL    604800
@       IN      SOA     ns1.lan2.local. admin.lan2.local. (
                      2021011001 ; Serial
                      604800     ; Refresh
                      86400      ; Retry
                      2419200    ; Expire
                      604800 )   ; Minimum TTL

@       IN      NS      ns1.lan2.local.

ns1     IN      A       192.168.2.1   ; 内网 DNS 服务器的 IP

host1   IN      A       192.168.2.2
host2   IN      A       192.168.2.3
```

### 3.4 配置反向 DNS(可选)

希望支持反向解析(IP → hostname)时配。假设:

- `lan1`:`192.168.1.0/24`
- `lan2`:`192.168.2.0/24`

在 `/etc/bind/named.conf.local` 追加:

```conf
zone "1.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.192.168.1";
};

zone "2.168.192.in-addr.arpa" {
    type master;
    file "/etc/bind/db.192.168.2";
};
```

再分别创建 `db.192.168.1` 和 `db.192.168.2` 反向区域数据文件。

## 4. 检查 BIND 配置

```bash
sudo named-checkconf
sudo named-checkzone lan1.local /etc/bind/db.lan1.local
sudo named-checkzone lan2.local /etc/bind/db.lan2.local
```

## 5. 重启 BIND9

```bash
sudo systemctl restart bind9
```

## 6. 防火墙放行(如果启用了 ufw)

DNS 默认端口 53(UDP + TCP):

```bash
sudo ufw allow 53
```

## 7. 测试

```bash
dig @localhost lan1.local
nslookup lan1.local 127.0.0.1
```
