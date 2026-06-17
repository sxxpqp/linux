# HAProxy 代理 ingress-nginx

L4 TCP 模式代理 N 台 ingress-nginx 节点(80/443 TLS 透传)。

## 架构

```
                            +-------------------+
                            |   DNS / VIP / IP  |
                            +---------+---------+
                                      |
                                      v
                            +-------------------+
                            |     HAProxy       |   ← 本目录
                            |  edge VM/物理机    |
                            |  :80 :443 :8404   |
                            +----+----+---------+
                                 |    |
                  TCP 透传 80    |    | TCP 透传 443(TLS 不解)
                                 v    v
              +---------------------+  +---------------------+
              | ingress-nginx node1 |  | ingress-nginx node2 | ...
              | hostNetwork 80/443  |  | hostNetwork 80/443  |
              +----------+----------+  +----------+----------+
                         |                        |
                         v                        v
                     Kubernetes Services / Pods
```

## 部署

### 1. 装 HAProxy(在边缘节点上)

```bash
# 把本目录拷到目标机器
scp -r D:/code/linux/haproxy/ root@haproxy-host:/tmp/

# 在目标机器上跑
ssh root@haproxy-host
cd /tmp/haproxy
bash install.sh --ingress-nodes=192.168.150.242,192.168.150.243
```

脚本会:
1. 装 `haproxy` 系统包(apt/yum/dnf)
2. 从 `haproxy.cfg.tpl` 渲染出 `/etc/haproxy/haproxy.cfg`
3. `haproxy -c` 语法检查
4. `systemctl enable && start haproxy`
5. 输出 stats UI 地址 + 自动生成的密码

### 2. DNS / VIP 指向 HAProxy

把域名 `test-dsp.wishfoxs.com` 等的 A 记录改成 HAProxy 节点 IP,流量就开始流过 HAProxy 了。

## 常见操作

### 加 / 删后端 ingress 节点
```bash
sudo vim /etc/haproxy/haproxy.cfg
# 在 backend bk_ingress_http / bk_ingress_https 里照样追加:
#   server ingress3 10.0.0.3:80  check inter 2s fall 3 rise 2
#   server ingress3 10.0.0.3:443 check inter 2s fall 3 rise 2

sudo haproxy -c -f /etc/haproxy/haproxy.cfg   # 语法检查
sudo systemctl reload haproxy                 # 无 downtime 热加载
```

或者直接重跑 install.sh,会覆盖配置(旧的会备份为 haproxy.cfg.bak.YYYYMMDD_HHMMSS):
```bash
sudo bash install.sh --ingress-nodes=10.0.0.1,10.0.0.2,10.0.0.3
```

### 状态监控页
浏览器开 `http://<haproxy-ip>:8404/stats`,用户名 `admin`,密码看安装日志。
能实时看到:
- 每个后端节点 UP / DOWN
- 当前连接数 / 总请求数 / 错误数
- 健康检查最近一次状态

### 看实时日志
```bash
sudo journalctl -u haproxy -f
```

## 想要客户端真实 IP

默认 L4 透传模式下,ingress-nginx 看到的源 IP 是 HAProxy 的 IP。要拿真实客户端 IP:

### A. 启用 PROXY protocol v2(推荐,改动小)
1. `/etc/haproxy/haproxy.cfg` 里每个 `server` 行末尾加 `send-proxy-v2`:
   ```
   server ingress1 10.0.0.1:443 check send-proxy-v2 inter 2s fall 3 rise 2
   ```
2. ingress-nginx 的 ConfigMap(`ingress-nginx-controller`)加:
   ```yaml
   data:
     use-proxy-protocol: "true"
   ```
3. 滚更 ingress-nginx:`kubectl -n ingress-nginx rollout restart ds/ingress-nginx-controller`
4. HAProxy reload:`systemctl reload haproxy`

之后 nginx `$remote_addr` 就是真实客户端 IP。

### B. 不动 L4,改用 HTTP 模式 + X-Forwarded-For
缺点:HAProxy 要做 TLS 终结,证书要往 HAProxy 上搬,复杂度+1。不推荐除非有 WAF / 限流需求。

## 想要高可用(HAProxy 自己不能挂)

单 HAProxy 是单点。要 HA:

### 加一台 HAProxy + Keepalived 拉 VIP
1. 第二台机器同样跑 `bash install.sh ...`
2. 两台都装 `keepalived`,一台 MASTER 一台 BACKUP,共享一个 VIP
3. DNS 解析到 VIP

Keepalived 简化版配置(MASTER):
```conf
vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 200
    advert_int 1
    authentication { auth_type PASS; auth_pass YourPass }
    virtual_ipaddress { 192.168.150.250 }
    track_script { chk_haproxy }
}

vrrp_script chk_haproxy {
    script "killall -0 haproxy"
    interval 2
    weight -50
}
```

BACKUP 机器把 `state` 改 `BACKUP`、`priority` 改 `100` 即可。

## 关键文件
| 文件 | 用途 |
|---|---|
| `install.sh` | 一键装 / 渲染配置 / 启服务 |
| `haproxy.cfg.tpl` | 配置模板,带占位符 `INGRESS_SERVERS_HTTP` 等 |
| `/etc/haproxy/haproxy.cfg` | install.sh 渲染出的实际配置 |
| `/etc/haproxy/haproxy.cfg.bak.*` | 旧配置自动备份 |

## 验证清单

```bash
# 1. 服务起着没
systemctl status haproxy

# 2. 端口在听没
ss -tlnp | grep haproxy

# 3. 后端 ingress 健康检查 UP 没
curl -s http://localhost:8404/stats | grep -E "(ingress|UP|DOWN)" | head

# 4. 端到端打一个请求
curl -skI https://<haproxy-ip>:443 -H 'Host: test-dsp.wishfoxs.com'
```
