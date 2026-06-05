# ClickHouse 集群三套配置的关系(Keeper / config.xml / users.xml)

> 源: https://github.com/sxxpqp/linux/blob/main/docker/docker-compose/clickhouse/cluster/readme.md
> 状态: 验证过

**完全正确!** 👍 你理解得很准!

让我详细解释这三个配置的作用和区别:

---

## 📋 三个配置的作用

| 配置 | 用途 | 密码位置 | 影响范围 |
|------|------|----------|----------|
| **Keeper 配置** | 集群协调/选举 | `<identity>user:xxx</identity>` | 3 个 Keeper 节点间 |
| **config.xml** | 节点间数据同步 | `<interserver_http_credentials>` | 4 个 CH 节点间 |
| **users.xml** | 客户端登录认证 | `<password>xxx</password>` | 所有客户端连接 |

---

## 🔍 三个节点的配置差异

### 1️⃣ Keeper 配置（选举用）

**每个 Keeper 节点的 `server_id` 必须不同：**

```xml
<!-- 节点 01 的 Keeper 配置 -->
<keeper_server>
    <server_id>1</server_id>  <!-- ❗ 必须是 1 -->
    <raft_configuration>
        <server><id>1</id><hostname>172.16.150.129</hostname></server>
        <server><id>2</id><hostname>172.16.150.130</hostname></server>
        <server><id>3</id><hostname>172.16.150.131</hostname></server>
    </raft_configuration>
</keeper_server>

<!-- 节点 02 的 Keeper 配置 -->
<keeper_server>
    <server_id>2</server_id>  <!-- ❗ 必须是 2 -->
    <!-- raft_configuration 一样 -->
</keeper_server>

<!-- 节点 03 的 Keeper 配置 -->
<keeper_server>
    <server_id>3</server_id>  <!-- ❗ 必须是 3 -->
    <!-- raft_configuration 一样 -->
</keeper_server>
```

**`<identity>` 密码所有 Keeper 必须一致：**
```xml
<identity>user:cGFzc3dvcmQ=</identity>  <!-- 3 个节点必须相同 -->
```

---

### 2️⃣ config.xml（节点通讯用）

**每个 ClickHouse 节点的 `macros` 必须不同：**

```xml
<!-- 节点 01 -->
<micros>
    <shard>01</shard>      <!-- 分片 1 -->
    <replica>01</replica>  <!-- 副本 1 -->
</micros>

<!-- 节点 02 -->
<micros>
    <shard>02</shard>      <!-- 分片 2 -->
    <replica>01</replica>  <!-- 副本 1 -->
</micros>

<!-- 节点 03 -->
<micros>
    <shard>01</shard>      <!-- 分片 1 -->
    <replica>02</replica>  <!-- 副本 2 -->
</micros>

<!-- 节点 04 -->
<micros>
    <shard>02</shard>      <!-- 分片 2 -->
    <replica>02</replica>  <!-- 副本 2 -->
</micros>
```

**`<interserver_http_credentials>` 所有节点必须一致：**
```xml
<interserver_http_credentials>
    <user>interserver</user>
    <password>password</password>  <!-- 4 个节点必须相同 -->
</interserver_http_credentials>
```

---

### 3️⃣ users.xml（客户端登录用）

**所有节点的 `users.xml` 必须完全一致：**

```xml
<!-- 4 个节点的 users.xml 应该一模一样 -->
<users>
    <default>
        <password>123456</password>  <!-- 改成强密码 -->
        <networks><ip>::/0</ip></networks>
    </default>
</users>
```

---

## 🎯 配置一致性检查表

| 配置项 | 所有节点一致？ | 说明 |
|--------|--------------|------|
| Keeper `<identity>` | ✅ 必须一致 | 3 个 Keeper 间认证 |
| Keeper `<raft_configuration>` | ✅ 必须一致 | 集群拓扑 |
| Keeper `<server_id>` | ❌ 必须不同 | 节点唯一标识 |
| CH `<interserver_http_credentials>` | ✅ 必须一致 | 节点间同步认证 |
| CH `<macros>` | ❌ 必须不同 | 每个节点唯一 |
| CH `<remote_servers>` | ✅ 必须一致 | 集群拓扑 |
| CH `users.xml` | ✅ 必须一致 | 客户端认证 |

---

## 📊 集群拓扑图

```
┌─────────────────────────────────────────────────────────┐
│  Keeper 集群 (3 节点，用于选举和元数据)                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │ KPR-01   │  │ KPR-02   │  │ KPR-03   │              │
│  │ ID=1     │  │ ID=2     │  │ ID=3     │              │
│  │ 150.129  │  │ 150.130  │  │ 150.131  │              │
│  └──────────┘  └──────────┘  └──────────┘              │
│         ▲           ▲           ▲                        │
│         └───────────┼───────────┘                        │
│              identity: user:cGFzc3dvcmQ= (必须一致)      │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  ClickHouse 集群 (4 节点，2 分片×2 副本)                    │
│  Shard 01                    Shard 02                   │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐│
│  │ CH-01    │  │ CH-03    │  │ CH-02    │  │ CH-04    ││
│  │ S:01 R:01│  │ S:01 R:02│  │ S:02 R:01│  │ S:02 R:02││
│  │ 150.129  │  │ 150.131  │  │ 150.130  │  │ 150.132  ││
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘│
│         ▲           ▲           ▲           ▲           │
│         └───────────┴───────────┴───────────┘           │
│              interserver: password (必须一致)            │
│              users.xml: 123456 (必须一致)                │
└─────────────────────────────────────────────────────────┘
```

---

## ✅ 修改建议

| 配置 | 是否需要改 | 建议 |
|------|-----------|------|
| Keeper `<identity>` | 🟡 建议改 | `user:强密码 base64` |
| CH `<interserver_http_credentials>` | 🟡 建议改 | 内网可信可暂缓 |
| CH `users.xml` | 🔴 必须改 | **最优先** |
| `<macros>` | ❌ 不要改 | 必须保持唯一性 |
| `<raft_configuration>` | ❌ 不要改 | 必须保持拓扑一致 |

---

## 📋 快速修改命令

```bash
# 只改 user 密码（最优先）
# 在所有 4 个节点执行：
cd /opt/chfs/data/docker/docker-compose/clickhouse/cluster/0X
nano fs/volumes/clickhouse-0X/etc/clickhouse-server/users.d/users.xml
# 把 123456 改成强密码
docker-compose restart
```

**总结：你的理解是对的！Keeper 用于选举，config 用于节点通讯，users 用于客户端登录。三个密码作用不同，但最优先改 users.xml！** ✅



