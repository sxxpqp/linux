# archived/

已停用 / 已迁移 / 仅做参考的 docker-compose 模板,**不再生产使用**,但保留内容方便以后查阅或抄回片段。

| 目录 | 原用途 | 现状 / 替代方案 |
|---|---|---|
| `clash/` | clash 代理客户端配置 (config.yaml / clash-yacd.yaml) | 已被 mihomo 取代,见 `network/mihomo/`(CLAUDE.md 顶层有说明) |
| `lucky/` | 反向代理工具 lucky 的钉钉 webhook 通知模板 | 仅一份 readme.md (含 dingtalk access_token),不是 compose,挪过来归档 |
| `sonarqube-old/` | SonarQube 7.7-community + postgres (无版本号) | 上层 `sonarqube/docker-compose.yaml` 已升到 community 主线 + postgres:17,旧版只留作回滚参考 |

如果你想完全删除,直接 `git rm -r archived/<目录>` 即可 — git history 里还能查到。
