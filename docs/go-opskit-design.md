# go-opskit 设计文档

> 状态：设计草案，尚未实现
> 日期：2026-10-15
> 项目名称：go-opskit；命令名称：opskit
> 定位：用 Go 封装网络排查、数据库备份和 S3 文件传输的命令行工具箱。

## 1. 目标与边界

目标是在服务器或容器中放入一个 `opskit` 二进制，即可执行常用网络检查和文件传输，减少临时安装 ping、telnet、wget、ss、netstat 的操作。数据库备份使用官方客户端，由 Go 统一编排、压缩、校验和上传。

第一版面向 Linux amd64/arm64。macOS、Windows 后续支持网络探测和文件传输；Linux socket 查询不承诺跨平台实现。名称为工作名称，尚未核实 GitHub 仓库名和商标可用性。

第一版不实现完整 Telnet 协议、不完整复刻系统命令参数、不实现数据库物理备份、增量备份或自动恢复，不内置常驻调度器。备份由 cron、systemd timer 或 Kubernetes CronJob 调度。

## 2. 功能范围

| 模块 | 第一版能力 | 依赖与限制 |
|---|---|---|
| ping | IPv4/IPv6 ICMP、次数、间隔、超时、丢包率和 RTT | Linux 权限与内核配置决定 ICMP socket 是否可用 |
| telnet / tcp | TCP 建连检查、超时、连接耗时；telnet 为 tcp 的别名 | 第一版不提供交互终端、协议协商或 TLS 检查 |
| dns | 指定解析器查询 A/AAAA，输出地址与耗时 | 使用 Go 解析接口；通用 DNS 记录查询后续扩展 |
| wget | HTTP/HTTPS GET、重定向、超时、进度、SHA-256 校验 | 第一版不支持断点续传、多连接加速或自动执行下载文件 |
| ss / netstat | TCP/UDP、IPv4/IPv6、监听与连接状态、可选进程信息 | Linux；默认只看到当前网络命名空间 |
| db backup | MySQL/PostgreSQL 单库逻辑备份、压缩、清单、可选上传 | 需要匹配版本的 mysqldump/pg_dump |
| s3 | 上传、下载、列举、Head 校验 | S3 兼容 API；endpoint、region 等由实际配置提供 |
| config | 配置结构校验、脱敏展示 | 不输出密码、Token 或凭据文件内容 |
| doctor | 本地能力与显式目标的连通性检查 | 不导出数据库、不修改 bucket、不自动安装依赖 |

## 3. 命令接口

```bash
opskit version
opskit ping example.com -c 4 --timeout 2s
opskit tcp 192.168.1.10 3306 --timeout 3s
opskit telnet 192.168.1.10 3306
opskit dns example.com --server 192.168.1.1:53
opskit wget https://example.com/file -o ./file --sha256 <期望值>

opskit ss -lntp
opskit ss -ant --port 3306
opskit netstat -ant

opskit config validate
opskit config show --redact
opskit doctor
opskit doctor --database mysql-prod --storage backup-store

opskit db backup mysql-prod
opskit db backup mysql-prod --upload backup-store
opskit db backup pg-prod --dry-run
opskit db cleanup mysql-prod --dry-run
opskit db cleanup mysql-prod --apply

opskit s3 upload ./backup.sql.gz backup-store --key manual/backup.sql.gz
opskit s3 download backup-store manual/backup.sql.gz -o ./backup.sql.gz
opskit s3 ls backup-store --prefix mysql-prod/
```

通用参数为 `--config`、`--output table|json`、`--quiet`、`--verbose`。网络超时与任务总超时分开定义；备份使用 `--timeout` 覆盖任务期限。stdout 输出结果，stderr 输出进度和诊断；JSON 模式不混入进度条。

`ss` 首批支持 `-l`、`-a`、`-n`、`-t`、`-u`、`-p` 和组合短参数；默认显示非监听 TCP 连接。`netstat` 复用同一数据源，作为兼容入口，不假定其他 netstat 参数均可用。未知参数返回明确错误。

退出码：`0` 成功；`1` 操作失败；`2` 参数或配置错误；`3` 缺少依赖或权限；`4` 超时；`5` 备份已完成但上传或远端验证失败；`130` 用户中断。ping 默认至少收到一次回应才成功，提供 `--require-all` 要求全部回应。socket 查询成功但部分 PID 不可见时保留结果并告警，不伪报为无连接。

## 4. 配置设计

默认查找顺序：`--config` → `OPSKIT_CONFIG` → 当前目录 `config/config.yaml` → 可执行文件目录 `config/config.yaml`。使用首个命中的配置，不自动合并多个文件。显式指定但不存在的文件直接报错。纯网络命令不要求配置文件存在。

路径字段相对所加载配置文件所在目录解析。命令参数覆盖配置项；凭据使用显式 `*_env` 或 `*_file` 引用，未定义的环境变量直接报错，不作为空密码继续执行。环境变量并不自动覆盖任意字段。

```yaml
schema_version: 1

network:
  connect_timeout: 3s
  request_timeout: 30s

backup:
  directory: ../data/backups
  timeout: 1h
  compression: gzip
  retain_local: 7

databases:
  mysql-prod:
    type: mysql
    host: 192.168.1.10
    port: 3306
    database: app
    username: backup
    password_env: MYSQL_BACKUP_PASSWORD
    dump_binary: /usr/bin/mysqldump
    tls:
      mode: verify-full
      ca_file: ./certs/mysql-ca.pem
    mysql:
      consistency: single-transaction
      routines: true
      events: true
      triggers: true
      gtid_purged: "OFF"

  pg-prod:
    type: postgres
    host: 192.168.1.11
    port: 5432
    database: app
    username: backup
    password_file: ./secrets/pg-password
    dump_binary: /usr/bin/pg_dump
    tls:
      mode: verify-full
      ca_file: ./certs/pg-ca.pem
    postgres:
      format: custom

storage:
  backup-store:
    type: s3
    endpoint: https://s3.example.com
    region: us-east-1
    bucket: backups
    prefix: opskit/
    path_style: true
    credentials:
      mode: env
      access_key_env: BACKUP_S3_ACCESS_KEY
      secret_key_env: BACKUP_S3_SECRET_KEY
      # session_token_env: BACKUP_S3_SESSION_TOKEN
    tls:
      verify: true
      # ca_file: ./certs/s3-ca.pem
    upload:
      concurrency: 4
      part_size: 16MiB
      timeout: 30m
      overwrite: false
```

示例地址不代表实际环境。MySQL `gtid_purged` 配置针对业务单库逻辑备份，不用于复制拓扑恢复；执行前按实际客户端能力验证。TLS 的统一字段映射到各数据库客户端参数，不支持的模式直接报错，不静默降低校验。

配置验证拒绝未知字段、重复 YAML key、非法时长、无效端口、路径冲突和无效引用。目标名称仅允许字母、数字、点、下划线和连字符，禁止路径穿越。文件凭据校验权限，真实配置与 secrets 目录加入 `.gitignore`。

镜像推送仓库、数据库和 S3 endpoint 均不内置个人环境默认值。先读取本项目文件与用户提供的信息；必要字段缺失时询问，不默认旧 Harbor、阿里云或其他历史环境。存储类型为 S3 不代表使用 AWS 托管服务。

## 5. 架构与目录

```text
CLI 参数与配置
      │
      ├── network：ICMP / TCP / DNS / HTTP
      ├── socket：Linux socket 采集、过滤、进程映射
      ├── database：客户端检测与导出编排
      ├── storage：S3 上传、下载与验证
      └── backup：任务锁、清单、保留策略
```

```text
go-opskit/
├── cmd/opskit/main.go
├── internal/
│   ├── cli/
│   ├── config/
│   ├── network/
│   ├── socket/
│   ├── database/
│   ├── storage/
│   ├── backup/
│   └── output/
├── config/config.example.yaml
├── testdata/
├── go.mod
├── go.sum
├── Dockerfile
├── .gitignore
└── README.md
```

CLI 层处理参数，不混入业务逻辑。各模块接收 `context.Context`；CLI 根上下文响应 SIGINT/SIGTERM。命令取消必须结束导出子进程、关闭流并停止上传。数据库程序使用 `exec.CommandContext` 和参数数组调用，不通过 `sh -c` 拼接。

依赖选择以 Go 标准库为主；CLI、YAML、ICMP/Netlink 和 S3 使用维护中的专用库，实施时核实兼容性并锁定版本。文档阶段不固定尚未验证的库版本。

## 6. 网络与连接查看实现

### 6.1 网络探测与下载

TCP 使用 `net.Dialer`，区分 DNS 失败、拒绝连接、不可达和超时。DNS 使用自定义 Resolver 指定目标服务器。ICMP 优先使用当前系统允许的 socket 类型；缺权限时提示所需能力，不自动改 sysctl 或给二进制提权，不用 TCP 成功冒充 ICMP 成功。

HTTP 使用 Go 客户端，默认校验证书；自签名服务可配置 CA。下载写入同目录临时文件，校验并关闭文件后再完成发布；默认不覆盖已存在目标。限制重定向次数，跨主机重定向不转发敏感认证头。第一版失败后不承诺续传，保留原目标文件。

### 6.2 ss / netstat

Linux 优先用 `NETLINK_SOCK_DIAG` 获取 TCP/UDP socket 信息；在接口不可用且错误允许回退时，读取 `/proc/net/{tcp,tcp6,udp,udp6}`。权限错误与不支持分开报告，不把失败当作空列表。内核接口依据见 [sock_diag(7)](https://man7.org/linux/man-pages/man7/sock_diag.7.html)。

`-p` 通过 socket inode 与 `/proc/<pid>/fd` 建立映射，按需读取进程名；权限不足时显示 `-` 并输出告警。结果是瞬时快照，进程退出和连接变化属于正常竞争条件。输出包含协议、状态、本地/远端地址、队列信息和可见进程；回退数据不含某字段时标注不可用。

容器默认只查询当前网络命名空间；主机连接可见性需要用户选择主机网络等运行方式，进程映射还受 PID 命名空间和 proc 权限约束。第一版不自动切换 namespace，不要求 privileged 容器。

## 7. 数据库备份设计

### 7.1 实现选择

| 方案 | 优点 | 代价 | 决策 |
|---|---|---|---|
| Go 驱动自行导出 | 无外部导出程序 | DDL、视图、触发器、一致性和版本兼容维护复杂 | 不作为完整备份实现 |
| Go 调度官方逻辑备份客户端 | 复用成熟格式和恢复生态 | 需要管理客户端版本 | 第一版采用 |
| 物理/增量备份工具 | 适合大库和恢复时间要求高的场景 | 部署、权限和恢复链复杂 | 后续独立能力 |

独立二进制包含网络、压缩和 S3 能力，但不声称内含数据库导出程序。缺少客户端时只让相关备份命令失败，其他工具仍可用，不自动下载安装。

### 7.2 MySQL

单库导出使用事务一致性模式及流式读取，视图、触发器、存储过程、事件按配置处理。`--single-transaction` 不能保证非事务表的一致性，备份期间并发 DDL 也可能影响结果；遇到非事务表按配置拒绝或要求明确接受限制。执行前验证实际账号权限，不能把“能登录”视作“可以完整备份”。[MySQL mysqldump 官方说明](https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html)

密码写入受限权限的临时客户端配置，作为 defaults 文件传入，不出现在进程参数或日志；正常结束、中断、失败均清理本任务临时凭据。MySQL 与 MariaDB 客户端不能无条件互换，版本和选项适配在发布矩阵中验证。

### 7.3 PostgreSQL

默认采用 `pg_dump --format=custom`，输出 `.dump`，不再外层 gzip；MySQL SQL 输出按配置 gzip。单库备份不包含全局角色和 tablespace 定义，不将其称为整个数据库实例备份。

通过受限权限临时 passfile 传递密码并设置 `PGPASSFILE`，正确转义特殊字符。优先使用与服务端同主版本客户端；客户端不能导出高于自身主版本的服务端，版本不兼容时提前失败。恢复到其他版本需另行验证。[PostgreSQL pg_dump 官方说明](https://www.postgresql.org/docs/current/app-pgdump.html)

### 7.4 任务状态与文件

```text
校验配置与客户端 → 获取目标锁 → 导出 .partial
  → 完成压缩与关闭文件 → 计算 SHA-256 → 发布本地成品与 manifest
  → 可选 S3 上传 → 远端验证 → 更新 manifest → 返回结果
```

每次任务生成独立 task_id。相同数据库目标默认不并发，使用操作系统文件锁，进程退出自动释放；不同机器之间的并发不由本地锁保证。路径按目标名称和 UTC 时间组织，task_id 防止同秒重名：

```text
data/backups/mysql-prod/20261015T020000Z-<task-id>/
├── app.sql.gz
└── manifest.json
```

manifest 包含任务 ID、数据库类型/名称、服务端和客户端版本、起止时间、产物名称、大小、SHA-256、备份状态、上传状态和远端 key，不包含密码。产物存在但 manifest 尚未完成的任务不得被清理器判为成功备份；清单更新使用临时文件加同目录原子替换。

导出失败或压缩失败保留明确失败状态，不将 `.partial` 改成最终文件。上传失败保留完整本地备份，返回退出码 5。重试上传复用该成品，无需再次导出。中断不标成功，不自动删除其他任务文件。

## 8. S3 与保留策略

对象 key 默认为 `<prefix>/<database>/<UTC日期>/<task-id>/<filename>`。默认不覆盖已存在对象；并发写入的防覆盖需后端条件写支持，单次 HEAD 检查不保证原子性。备份任务使用唯一 key 避免竞争。

凭据支持配置指定的环境变量或显式选择 SDK 默认凭据链；二者互斥，不静默切换身份。endpoint、region、bucket、path-style 和 CA 按服务实际情况配置，不自动创建 bucket。

大文件使用分段上传；并发和 part size 有边界校验，按对象大小调整以符合服务端限制。仅重试可重试错误，设置退避、次数与总超时；失败或取消时尽力 Abort 本任务 multipart upload，服务端残留由 bucket 生命周期兜底。凭据、URL 签名和认证头不进入日志。

本地 SHA-256 是产物校验依据，ETag 不当作通用 MD5。上传后使用 HEAD 核对长度、任务标识及 metadata；这只能确认对象属性，不等同于远端内容已逐字节校验。后端支持时验证明确的 checksum API，否则可用 `--verify-download` 回读计算 SHA-256。仅在数据对象验证完成后上传远端 manifest 作为本任务完成标识。

`retain_local` 只作用于 opskit 自己生成且 manifest 有效的任务目录，不扫描任意 SQL 文件。清理默认 dry-run，`--apply` 才删除；要求目标目录位于已解析备份根目录内，拒绝符号链接逃逸。需要远端备份的任务只有上传已验证后才能被本地保留策略删除。第一版不自动清理 S3 对象，远端保留由 bucket 生命周期管理。

## 9. doctor 与可观测性

默认 doctor 仅检查本地配置、目录可写性、磁盘空间、导出程序版本和网络能力；指定 `--database`、`--storage` 后才检查对应外部服务。数据库检查建立受超时限制的只读连接，不导出数据；S3 使用目标所允许的只读请求，不上传测试对象。

S3 403、404 和网络失败分别报告，不能因缺少 HeadBucket/ListBucket 权限就断言上传权限不存在。doctor 展示实际验证过的能力和未验证项；只读探测不能证明 PutObject 权限。

备份结果输出 task_id、本地路径、字节数、耗时、checksum、上传状态和失败阶段。JSON 输出固定 schema_version。日志中显示目标别名而非含密码 DSN；错误保留底层原因，但过滤凭据。

## 10. 构建与发布

交付 Linux amd64/arm64 独立二进制、SHA-256 清单和可选容器镜像。二进制尽量保持纯 Go；只有确需 CGO 的依赖才启用，并单独说明运行库需求。

容器分为 core 与 backup 两类：core 仅包含 opskit、CA 和必要运行文件；backup 包含 opskit 与经过测试的数据库客户端。客户端版本记录在镜像标签和版本输出中，不能宣称一个客户端版本兼容所有数据库。

Dockerfile 第三方 FROM 保留上游地址。镜像仓库先从项目配置读取，缺失时询问，不内置个人仓库。配置、秘密和备份目录通过挂载提供，不烘焙进镜像。备份与上传以非 root 运行；ping 的额外权限单独配置，不默认 privileged。

GitHub 发布工作流在实施时确定；代码检查与构建通过后才能生成候选产物，正式 Release 需明确版本和发布授权。仓库只提交示例配置，不包含实际凭据或数据库备份。

## 11. 测试与验收

| 范围 | 必须验证的行为 |
|---|---|
| 配置 | 缺文件、未知字段、重复 key、缺环境变量、路径解析、已有配置不重复询问 |
| 网络 | TCP 成功/拒绝/超时、IPv6、ICMP 无权限、DNS 失败、HTTP 状态码和校验失败 |
| socket | Netlink/proc 数据解析、过滤、组合参数、PID 不可见、不同 namespace 可见性 |
| 数据库 | MySQL/PG 客户端匹配、权限不足、导出中断、压缩失败、非事务表限制 |
| S3 | 实际兼容服务上传/下载、分段失败、取消、checksum、403、目标已存在 |
| 备份流程 | 上传失败保留本地成品；失败任务不伪报成功；清理不越界、不删未完成任务 |
| 恢复演练 | 将样本备份恢复到隔离数据库，核验 schema、行数、样本数据与声明支持的对象 |

单元测试使用本地服务和 fixture；集成测试使用隔离数据库和 S3 兼容服务，不连接生产。发布前执行 `go test ./...`、竞态检查及目标平台编译；网络内核能力在真实 Linux 主机或具备对应内核接口的容器验证。

“下载成功”“备份文件非空”“Head 返回 200”均不等于恢复成功。数据库备份能力必须通过隔离环境恢复演练后才标为已验证。备份上限与性能不预先编造，验收时记录数据规模、硬件、压缩方式、耗时和峰值内存。

## 12. 迭代计划

| 阶段 | 内容 | 完成条件 |
|---|---|---|
| M1：基础工具 | CLI、配置、TCP/DNS/wget/ping、结构化输出 | 无配置可运行网络命令；超时和退出码可验证 |
| M2：连接查看 | ss/netstat、进程映射和权限降级 | Linux TCP/UDP/IPv4/IPv6 代表场景验证通过 |
| M3：S3 | 上传、下载、列举、校验与取消 | 至少一个实际 S3 兼容服务集成验证通过 |
| M4：数据库 | MySQL/PG 导出、manifest、上传编排、清理 | 客户端兼容矩阵和隔离恢复演练通过 |
| M5：交付 | 双架构二进制、容器、示例配置和使用说明 | 发布产物可校验、镜像配置不含真实秘密 |

第一版完成标准：网络和连接查看不调用宿主机 ping/telnet/wget/ss/netstat；数据库客户端依赖清楚可检测；配置缺项有明确提示；完整备份可恢复；失败可追踪且不删除有效备份。
