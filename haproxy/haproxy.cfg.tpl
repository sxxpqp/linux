# ============================================================
# HAProxy 配置模板 —— 由 install.sh 通过 awk 替换占位符后生成
# 用途:L4 TCP 模式代理 N 台 ingress-nginx(80/443)
#   - TLS 透传(passthrough),不在 HAProxy 终结证书,由后端 ingress-nginx 处理
#   - leastconn 算法:把新连接发给当前连接数最少的后端,适合长连接 / HTTP/2
#   - 8404 端口提供 stats UI(用户名 admin,密码由 install.sh 注入)
#
# 占位符位置见下方 backend / stats 段;install.sh 渲染时自动替换。
# (本注释段刻意不写完整的占位符标识,防止 awk 误把说明文档也替换掉)
# ============================================================

global
    daemon
    maxconn 100000
    log /dev/log local0 info
    user  haproxy
    group haproxy
    nbthread __NBTHREAD__                   # 工作线程数,install.sh 默认按 nproc 注入
    tune.ssl.default-dh-param 2048
    tune.bufsize 32768
    # PID 文件 / chroot,生产可加:
    # chroot /var/lib/haproxy
    # pidfile /run/haproxy.pid

defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  60s
    timeout server  60s
    timeout queue   5s
    timeout check   5s
    retries 3
    maxconn 50000

# ============================================================
# 80 端口:HTTP 流量 TCP 转发到 ingress-nginx
# ============================================================
frontend ft_http
    bind *:80
    default_backend bk_ingress_http

backend bk_ingress_http
    balance leastconn
    option tcp-check
    # ↓↓↓ ingress 节点列表(install.sh 自动生成)↓↓↓
__HTTP_BACKENDS__
    # ↑↑↑ 想加机器:照样式追加一行 server ingressN IP:80 check inter 2s fall 3 rise 2 ↑↑↑

# ============================================================
# 443 端口:HTTPS 流量 TLS 透传(TCP 转发,不解密)
# ============================================================
frontend ft_https
    bind *:443
    default_backend bk_ingress_https

backend bk_ingress_https
    balance leastconn
    option tcp-check
    # ↓↓↓ ingress 节点列表 ↓↓↓
__HTTPS_BACKENDS__

# ============================================================
# 8404 端口:状态监控页(浏览器开 http://<haproxy-host>:8404/stats)
# ============================================================
frontend ft_stats
    bind *:8404
    mode http
    stats enable
    stats uri      /stats
    stats refresh  10s
    stats realm    HAProxy\ Stats
    stats auth     admin:STATS_PASSWD
    # 想暴露给 Prometheus 抓:
    # http-request use-service prometheus-exporter if { path /metrics }

# ============================================================
# 可选:开启 PROXY protocol v2 让 ingress-nginx 拿到真实客户端 IP
# 启用步骤:
#   1) 上面 server 行末尾加 send-proxy-v2,如:
#        server ingress1 192.168.150.242:443 check send-proxy-v2 inter 2s ...
#   2) ingress-nginx ConfigMap(ingress-nginx-controller)加:
#        use-proxy-protocol: "true"
#   3) 重启 ingress-nginx controller
# 不启用的话,ingress-nginx 看到的源 IP 是 HAProxy 的 IP,不是真实客户端
# ============================================================
