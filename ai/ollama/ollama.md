# Ollama 安装 / 更新（Linux & macOS）

> 解决国内下载慢、卡住问题；重复执行自动检测版本，已是最新则跳过，否则升级。

## 一键安装 / 更新

```bash
bash <(curl -fsSL https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/ai/ollama/install.sh)
```

## 可选参数

```bash
# 指定版本
OLLAMA_VERSION=v0.x.y bash <(curl -fsSL <上方地址>)

# 手动换加速节点
OLLAMA_GH_PROXY=https://ghfast.top/ bash <(curl -fsSL <上方地址>)

# Linux 不安装 systemd 服务
bash <(curl -fsSL <上方地址>) --no-service
```

## 脚本做了什么

| 步骤 | 行为 |
|------|------|
| 识别环境 | 自动判断 Linux / macOS，amd64 / arm64 |
| 选代理 | 依次探测 `ghproxy.cn` → `ghfast.top` → `gh-proxy.org` → 直连，选第一个通的 |
| 幂等判断 | 比较已装版本与最新版，一致直接退出 |
| Linux | 下载 tgz → 清旧库 → 解压到 `/usr` → 配置 systemd |
| macOS | 下载 zip → 装到 `/Applications` → 软链 CLI |


## 常见问题

| 现象 | 处理 |
|------|------|
| `bad interpreter` | 脚本 CRLF 换行，执行 `sed -i 's/\r$//' install.sh` |
| 版本号解析失败 | `OLLAMA_VERSION=v0.x.y bash ...` 手动指定 |
| 升级后仍是旧版 | `sudo rm -rf /usr/lib/ollama` 后重跑 |
| 局域网访问 | 服务已设 `OLLAMA_HOST=0.0.0.0`，放行 11434 端口 |