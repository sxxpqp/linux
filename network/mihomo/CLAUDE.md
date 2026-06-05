# mihomo 代理 — AI 协作上下文

> 项目: https://github.com/sxxpqp/linux

## 基本信息

| 项 | 值 |
|---|---|
| 运行主机 | `node02` (192.168.150.253, enp1s0) |
| 运行方式 | **systemd 服务**，`systemctl {start\|stop\|restart\|status} mihomo` |
| 配置文件（服务器） | `/etc/mihomo/config.yaml` |
| 本仓库归档 | `network/mihomo/config.yaml`（从服务器同步回来，**改这里 ≠ 改生产**） |
| 控制面板 | `external-controller: 0.0.0.0:9090`（已开启），WebUI 见下 |
| 模式 | **TUN 模式**（stack: mixed），DNS fake-ip，全局透明代理 |

## 配置同步流程

```bash
# 改完本仓库文件后，推到服务器：
scp network/mihomo/config.yaml root@node02:/etc/mihomo/config.yaml
ssh root@node02 "systemctl restart mihomo"

# 或者服务器上直接 git pull：
ssh root@node02 "cd /path/to/linux && git pull && cp network/mihomo/config.yaml /etc/mihomo/config.yaml && systemctl restart mihomo"
```

## 关键配置说明

### 端口
- `mixed-port: 7890` — HTTP/SOCKS5 混合入站
- DNS 监听：`0.0.0.0:1053`（fake-ip 模式）
- 控制面板：`0.0.0.0:9090`

### TUN
- `stack: mixed`，`auto-route/auto-redirect/auto-detect-interface: true`
- 裸核模式（**不是** nikki 插件），注意注释里有 nikki 的备选配置，**不要误改**

### DNS
- fake-ip，`198.18.0.1/16`
- 上游全走阿里 DoH（`dns.alidns.com`）+ DNSPod（`doh.pub`）
- `respect-rules: true`：代理流量的 DNS 走代理解析

### rule-providers
全部走 Nexus `raw-githubusercontent` 代理（`nexus.ihome.sxxpqp.top:8443`），**不直连 raw.githubusercontent.com**。规则集来源：
- 大多数规则：`MetaCubeX/meta-rules-dat`（MRS 格式）
- fakeip-filter：`wwqgtxx/clash-rules`
- proxylite（自定义代理列表）：`qichiyuhub/rule`

### 机场订阅
`proxy-providers.Airport1.url` 里填订阅地址，当前是占位符，**真实订阅 URL 不入库**（敏感信息手动填到服务器上的 config.yaml）。

## 常用排查命令

```bash
# 查运行状态 / 日志
systemctl status mihomo
journalctl -u mihomo -f

# 重载配置（不重启进程，支持热更新）
curl -X PUT http://127.0.0.1:9090/configs?force=true \
  -H "Content-Type: application/json" \
  -d '{"path": "/etc/mihomo/config.yaml"}'

# 查当前代理规则命中
curl http://127.0.0.1:9090/connections

# 测试 DNS（fake-ip 下）
dig @127.0.0.1 -p 1053 google.com
```

## 注意事项

- **订阅 URL 不入库**：`Airport1.url` 在服务器上手动维护，同步配置时注意别把本仓库里的占位符覆盖掉。
- TUN 模式会接管 node02 全部流量，排查网络问题时先 `systemctl stop mihomo` 排除代理干扰。
- `log-level: warning`，日志默认安静，排查时改成 `debug` 再 `systemctl restart mihomo`。
- `external-controller` 已开启，不要暴露到公网，当前绑定 `0.0.0.0`，确认防火墙已限制 9090 端口访问范围。
