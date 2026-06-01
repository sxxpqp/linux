# traefik-trojan-go

Traefik 反代 + trojan-go 翻墙服务端的组合配置(**没有 docker-compose 文件**,只有 3 份 config):

- `traefik-trojan-go.yaml` — Traefik 静态/动态配置
- `trojan.yaml` — trojan-go 服务端配置
- `config.json` — 另一份 JSON 配置(用途未确认)

## ⚠ 状态待确认

仓库 `network/` 目录主线是 **mihomo**(裸核 TUN 模式),trojan-go 这套是否还在某台服务器上跑、是否还有人用,**未确认**。

下次到现场确认:
- 如果还在用 → 补一段"跑在哪台机器、监听端口、对应客户端配置"
- 如果已停 → `git mv traefik-trojan-go archived/traefik-trojan-go`
