# 排障案例范式 — 完整 8 步流程

> ⚠️ **按需启用** — 默认对照 CLAUDE.md "输出深度先评估"规则,L1 简单问题跳到第 ⑥/⑦ 步直接给修复+验证;L2 动手前问用户要详细还是简略;L3 生产事故才全程 8 步走完。
> 下面用真实案例(本仓库 commit `cd28fdb`)示范 L3 全套写法。

**案例**:`ai/dify/deploy.sh` 跑到 docker install 时报 `curl: (23) Failed writing body (0 != 13969)`

## ① 现象 — 贴用户原始输出,不脑补

```
[INFO] 正在安装 Docker CE...
Loaded plugins: fastestmirror
Cleaning repos: base docker-ce-stable extras kubernetes updates
Cleaning up list of fastest mirrors
curl: (23) Failed writing body (0 != 13969)
```

## ② 解读错误码 — 查文档,不猜

- `curl exit 23` = `CURLE_WRITE_ERROR`,curl 写 stdout 时被 pipe 关闭
- `(0 != 13969)` = curl 期望写 13969 字节,实际写 0 → **下游进程提前关闭 pipe**

## ③ 画出完整链路 — 标明 stdin/stdout 流向

```
curl ... | bash -s docker --mirror Aliyun </dev/null 2>&1 | grep ...
  ↓          ↓                              ↓                  ↓
fd 1     bash fd 0(stdin)                redirect          grep stdin
         期望从 pipe 收脚本               改成 /dev/null     收 bash 输出
```

故障定位:`</dev/null` 把 bash 的 stdin 改成 /dev/null → bash 读 EOF → exit 0 → pipe 关闭 → curl SIGPIPE → exit 23

## ④ 根因分析 — shell 语义层面

不是 docker / curl / yum 任何一个工具的 bug,**根因是 shell 解析顺序**:

```
cmd1 | cmd2 < file     # cmd2 的 stdin 是 file,不是 pipe
```

`bash -s` 模式要从 stdin 读脚本源,但 `</dev/null` redirect **优先级高于** pipe,bash 收不到脚本,所以提前退出。

## ⑤ 方案对比 — 给出 trade-off,说"为什么不是 B"

| 方案 | 优 | 劣 | 选择 |
|---|---|---|---|
| 直接删 `</dev/null` | 改 1 字符 | systemctl pager 会回来卡住 | ✗ 治标 |
| `setsid curl \| bash` | 不动 stdin,切 session | 老 CentOS 7 setsid 行为差异大 | ✗ 兼容性差 |
| `script -qc '...' /dev/null` 伪 tty 包一层 | 兜底有效 | 输出格式乱 + 跑两层 shell + 调试痛苦 | ✗ 复杂 |
| **`mktemp + curl -o + bash <file> </dev/null`** | stdin 跟脚本源彻底分开,两个 redirect 互不影响 | 多 3 行 + 清理 tmp | ✅ |

## ⑥ 修复 — 给完整 diff,不是片段

```diff
-            curl -fsSL <url> | bash -s docker --mirror Aliyun </dev/null 2>&1 | grep -v ...
+            local docker_install_sh
+            docker_install_sh=$(mktemp /tmp/docker-install.XXXXXX.sh)
+            curl -fsSL <url> -o "$docker_install_sh"
+            bash "$docker_install_sh" docker --mirror Aliyun </dev/null 2>&1 | grep -v ...
+            rm -f "$docker_install_sh"
```

## ⑦ 验证 — 跑一遍 + 给预期输出

```bash
bash /tmp/dify-deploy.sh 1.14.2 /opt/dify
# 期望: 不再出现 curl: (23),docker install 完整跑完,出现 "Client: Docker Engine - Community"
docker info >/dev/null && echo "✓ docker OK"
```

## ⑧ 沉淀 — 让下次不再撞

| 沉淀点 | 内容 |
|---|---|
| CLAUDE.md "已知踩坑"段 | 加第 7 条:`curl \| bash -s ... </dev/null` 死锁 |
| CLAUDE.md "反面案例"表 | 加 `mktemp + curl -o + bash` 的正确模式 |
| docs/script-conventions.md "脚本"标准 | 加"pipe / stdin 不抢占"一条 |
| commit message | 写 `fix(scope): rationale`,**不写 update**,以后 git log 能搜到 |

→ 三个月后另一个脚本同样问题,直接 grep CLAUDE.md "curl.*bash.*stdin" 就能找到全套解法,无需再排一遍。
