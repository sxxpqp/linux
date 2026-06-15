# MySQL InnoDB Cluster — db1 节点故障排查与修复记录

> 环境:MySQL 8.0.44 InnoDB Cluster（mysqlsh / AdminAPI 管理），三节点单主架构
> 集群名:myCluster
> 节点:db2（PRIMARY，可读写）/ db3（SECONDARY，只读）/ db1（故障节点）
> 性质:db1 磁盘 IO 反复故障导致节点无法加入集群，已是第三次复发

---

## 一、核心结论（先看这个）

- **根因是硬件，不是软件**:db1 的磁盘（sda，RAID/虚拟盘）IO 反复故障 —— SCSI 命令 180 秒超时、XFS 写入失败。
- **db1 卡在 RECOVERING / 移除卡 99% / clone 失败，全是同一个根**:坏盘让事务写不进本地、apply 不下去，所以分布式恢复和移除同步永远到不了 100%。
- **为什么之前"修好"又坏**:前两次只是重做数据绕过了症状，坏盘没换，所以反复发作（这是第三次）。
- **正确解法**:先让 IDC 修/换盘 → 确认磁盘读写正常 → 用 clone 全量重做节点。**先修硬件，再重做，才能真正不复发。**
- **生产影响**:全程 db2（主）+ db3（从）两节点正常服务，业务读写未受影响。

---

## 二、故障现象与排查证据

### 2.1 系统层（操作系统 / 磁盘）

**iostat 异常**:磁盘 100% 繁忙但吞吐为 0、队列大量积压 —— 典型的 IO 卡死（hung）特征。

```
sda    %util=100.00   avgqu-sz=225.00   r/s=0  w/s=0  rkB/s=0  wkB/s=0  await=0
dm-0   %util=100.00   avgqu-sz=231.00   r/s=0  w/s=0  rkB/s=0  wkB/s=0  await=0
```

> 解读:正常"进程狂写盘"应是 wkB/s 高、await 大。这里却是繁忙度 100%、队列积压 200+，但读写吞吐为 0、await 为 0 —— 说明请求只进不出、全部卡在队列等超时，是底层磁盘无响应（hung），而非某进程 IO 高。

**内核日志（dmesg）铁证**:

```
sd 2:0:0:0: [sda] timing out command, waited 180s
XFS (dm-0): writeback error on sector 1107550672
XFS (dm-0): writeback error on sector 1107553496
... (大量扇区写回失败)
```

> 解读:SCSI 命令等待 180 秒超时无响应；XFS 把脏页刷回磁盘时大量扇区写失败。数据落不了盘。

**进程卡 D 状态**(不可中断睡眠，被 IO 拖死):

```
13698 D    msleep [tq_kth]
```

**SMART 读不到物理盘健康值**:

```
smartctl -a /dev/sda  →  Error Counter logging not supported
```

> 解读:读不到标准物理盘 SMART 字段，说明 sda 是 RAID 逻辑盘 / 虚拟盘，物理盘健康状态需在后端或带外管理侧检查。

### 2.2 数据库 / 集群层

`cluster.status()` 显示 db1 长期卡在分布式恢复:

```
db1:3306  status: RECOVERING
recoveryStatusText: "Distributed recovery in progress"
```

> 解读:db1 要从 ONLINE 变正常，必须把落后事务拉来写到本地、apply 上去。坏盘让数据落不了盘，恢复永远走不完，故永远 RECOVERING。系统层与数据库层证据互相印证，同指坏盘。

排查过程中还遇到的衍生报错（均为坏盘 / 残留状态导致）:

- 移除时卡 99%:`unable to catch up with cluster transactions` / `Timeout reached waiting for transactions`
- 认证失败:`Access denied for user 'mysql_innodb_cluster_1'@'db1' (1045)`（复制账号与元数据不一致）
- 加入被拒:`The instance 'db1:3306' is already part of another InnoDB Cluster`（db1 本地残留旧集群身份）
- 元数据不一致:`server_id is not registered in the metadata` 等，提示 `cluster.rescan()`

---

## 三、排查命令速查

### 系统层

```bash
# 确认是否磁盘 IO 瓶颈（看 %util 是否接近 100、await 是否异常）
iostat -x 1

# 按进程看磁盘读写（高 IO 进程）
pidstat -d 1
iotop -oP

# 看磁盘/存储是否 hung —— 关键
dmesg -T | tail -80
dmesg -T | grep -iE "error|fail|reset|offline|abort|timing out|writeback" | tail -40

# 看阻塞进程（D 状态 = 被 IO 卡死）
ps -eo pid,stat,wchan,cmd | awk '$2 ~ /D/'

# 看阻塞队列与 IO 等待
vmstat 1 5

# 设备类型与挂载
lsscsi
lsblk -o NAME,TYPE,SIZE,MOUNTPOINT,FSTYPE
multipath -ll          # 如走 SAN / 多路径

# 物理盘健康（RAID 卡需穿透查）
yum install -y smartmontools
smartctl -a /dev/sda
smartctl -a -d megaraid,0 /dev/sda
```

### 集群层

```javascript
// mysqlsh 连主节点 db2
\connect root@db2:3306
var cluster = dba.getCluster()
cluster.status()
cluster.status({extended:1})       // 看每个成员恢复进度
```

---

## 四、修复流程（盘已修好后执行）

> **执行前提:db1 的盘已由 IDC 修复/更换，dmesg 不再报 SCSI 超时和 XFS 写错误。**

### 前置:连接到 db2 进入 mysqlsh（所有 cluster.xxx 命令的前提）

在任意能访问集群的机器上（db2 本机或管理机均可）:

```bash
mysqlsh
```
```javascript
// 连接到主节点 db2（db2 可换成实际主机名或 IP，会提示输入 root 密码）
\connect root@db2:3306

// 获取集群对象（后续所有 cluster.xxx 命令都依赖它）
var cluster = dba.getCluster()
```

> 说明:
> - 连上后提示符形如 `MySQL db2:3306 ssl JS >`，处于 JS 模式即可执行 `cluster.xxx`。
> - 若直接敲 `cluster.status()` 报 `cluster is not defined`，是漏了 `var cluster = dba.getCluster()` 这步。
> - 断线或重开窗口后，重复上面两条重新连接并取对象。

### 第 0 步:确认磁盘真的能写（db1 上执行）

```bash
dd if=/dev/zero of=/var/lib/mysql/iotest bs=1M count=512 oflag=direct && sync && rm -f /var/lib/mysql/iotest
```

秒完成、不卡 → 盘 OK，继续。卡住 → 盘未真正修好，停止操作。

### 第 1 步:停止 db1 的组复制（db1 上执行，可选，按习惯）

> db1 此时组复制通常已是 stopped/OFFLINE，本步可省。若按习惯先停，**务必确认连的是 db1**。

```bash
# 在 db1 机器上连本机（不要在连 db2 的会话里执行！）
mysql -h 127.0.0.1 -u root -p
```
```sql
SELECT @@hostname;          -- 必须返回 db1，确认后再执行下一条
STOP GROUP_REPLICATION;
```

> ⚠️ 危险提醒:`STOP GROUP_REPLICATION` / `RESET REPLICA ALL` 这类命令若误在连接 **db2（主节点）** 的会话里执行，会破坏主节点复制、直接影响生产。执行任何此类命令前先 `SELECT @@hostname;` 确认对象。

### 第 2 步:移除残留的 db1 节点（db2 的 mysqlsh 上执行）

```javascript
// db1 此时 OFFLINE，force 可直接抹掉元数据，不会卡同步
cluster.removeInstance('db1:3306', {force:true})
```

> 若提示 metadata not found，说明元数据里已无 db1，跳过本步直接下一步。

### 第 3 步:用 clone 全量重做加入（db2 的 mysqlsh 上执行）

```javascript
cluster.addInstance('db1:3306', {recoveryMethod:'clone'})
```

- clone 会从 SECONDARY（默认优先 db3）拉一份完整干净数据灌入 db1。
- **自动重建复制账号**，顺带解决之前的 1045 认证错误。
- **无需手工** `STOP GROUP_REPLICATION` / `RESET REPLICA ALL`，clone 流程自行接管组复制启停。
- 库大时耗时较长，建议挑业务低峰执行（donor 会有读 + 网络负载）。

> 注:`cloneDonor` 选项部分 mysqlsh 版本不支持（报 `Invalid options: cloneDonor`）。不指定 donor 即可，AdminAPI 默认优先选 SECONDARY（db3），本就避开主节点。

### 第 4 步:确认恢复成功（db2 上执行）

```javascript
cluster.status()
```

期望:db1 / db2 / db3 三节点全部 ONLINE，状态从 `OK_NO_TOLERANCE` 变回 `OK`（容错能力恢复）。

### 第 5 步:收尾

```bash
# db1 上,恢复开机自启（之前为防自动入组添乱曾 disable）
systemctl enable mysqld
```

清理 unused recovery account 等残留警告（如 `Detected an unused recovery account: mysql_innodb_cluster_1`）:

```javascript
// db2 上执行
cluster.rescan()
```

> **rescan 时机与注意事项（重要）:**
> - rescan 是"对账/清理"工具，**必须等 db1 已通过 clone 成功加回、三节点都 ONLINE 之后再做**。
>   在 db1 还没干净加回来之前 rescan，可能把脏状态/坏节点固化进元数据，反而添乱。
> - rescan 过程中若弹出交互提示，按下面应对:
>   - 问"发现新实例 db1，是否加入元数据? [Y/n]" —— db1 已正常 ONLINE 时一般不会再问；
>     若在 db1 尚未干净加回前被问到，**选 n**。
>   - 问"是否配置 `group_replication_view_change_uuid`（需整集群重启）? [Y/n]" —— **永远选 n**。
>     这是 InnoDB ClusterSet 才需要的配置，与本场景无关，且零容错时严禁整集群重启。

---

## 五、过程中踩过的坑（避免重蹈覆辙）

| 现象 | 真实原因 | 正确做法 |
|---|---|---|
| `removeInstance` 卡在 99% | 坏盘导致 db1 追不平最后事务 | 让 db1 离组/停 mysqld 后再 force 移除 |
| `force:true` 仍卡 99% | force 仅对"不可达"实例生效；db1 当时"连得上但追不平"不算不可达 | 先停 db1 mysqld → 等判为 MISSING → 再 force |
| db1 一启动就自动回到集群卡 RECOVERING | `group_replication_start_on_boot=ON` 默认自动入组 + 坏盘 | 处理期间 `systemctl stop + disable mysqld` |
| `already part of another InnoDB Cluster` | db1 本地残留旧集群身份，与 db2 元数据不一致 | 用 clone 重做（自动清理），或先清本地残留 |
| rescan 提示配 `group_replication_view_change_uuid`（需整集群重启） | 这是 InnoDB ClusterSet 才需要的配置 | **拒绝（选 n）**，零容错时严禁整集群重启 |
| kill -9 杀不掉卡住的进程 | D（不可中断睡眠）状态进程 kill 无效 | 不要强杀，等 IO 返回或停服务 |

**关键禁忌:**
- 盘 hung 时**不要贸然重启机器**（卸载文件系统可能卡死/加重损坏，且丢失现场）。
- 集群只剩两节点（零容错）期间，**不要对 db2/db3 做任何非必要的重启或变更** —— 再掉一个就不可写。
- **不要在连 db2 的会话里执行针对 db1 的 SQL**（尤其 STOP GROUP_REPLICATION / RESET REPLICA ALL）。

---

## 六、防复发建议

1. **认准老毛病**:db1 若再报 `timing out command` / `XFS writeback error`，第一时间查磁盘硬件、推 IDC，别再在 MySQL 层反复折腾。
2. **报障要说"反复"**:向 IDC 强调这是第三次反复发作、附内核超时与写失败日志，逼其检查物理盘/RAID 卡/背板/线缆并更换，而非只做重启。
3. **零容错期的纪律**:节点恢复到三节点之前，最高优先级是尽快补回第三节点；期间保护好 db2/db3。
4. **备份兜底**:确认存在异地备份/快照，并定期验证可恢复性。
5. **带外管理**:确认机器具备 IPMI/iDRAC/iLO，便于硬件故障时排查与恢复。

---

## 附:给 IDC 的报障要点（可直接引用）

> 服务器 db1（IP/机柜位/序列号:______）sda 磁盘 IO **反复故障，已第三次**，前两次重做数据临时恢复但很快复发。现象（均有内核日志）:
> 1. `sd 2:0:0:0: [sda] timing out command, waited 180s`（SCSI 命令 180 秒超时）
> 2. `XFS (dm-0): writeback error on sector ...`（大量扇区写失败）
> 3. iostat:%util 持续 100%、队列积压 200+、读写吞吐为 0
> 4. 内核线程进入 D（不可中断睡眠）状态
> 5. OS 层 smartctl 读不到物理盘 SMART（Error Counter logging not supported），判断为 RAID 逻辑盘/虚拟盘
>
> **诉求**:检查并更换故障物理磁盘 / RAID 卡 / 背板 / 线缆；鉴于反复发作，请勿仅做重启；操作前请沟通（有生产数据需协同）；请告知是否有带外管理及预计处理时间。