# VPA — Vertical Pod Autoscaler

> 上游: https://github.com/kubernetes/autoscaler/tree/vpa-release-1.0/vertical-pod-autoscaler
> 测试集群已验证 (K8s 1.28)。
> 依赖:metrics-server(先 `bash kubernetes/metrics-server/install.sh`)。

## 这个目录有什么

| 文件 | 用途 |
|---|---|
| [install.sh](install.sh) | 装 VPA(CRD + RBAC + recommender + updater),默认 Recommender 模式(只给建议,不动 Pod)。`--with-admission` 才装 Auto 模式 |
| [bulk-recommend.sh](bulk-recommend.sh) | 批量给 Deployment 建 VPA(`updateMode: Off`)/ dump 所有建议(内存自动换算 Mi/Gi)/ cleanup 只删本脚本建的 |
| [readme.md](readme.md) | 本文档 — 怎么用 + 怎么读建议 |

## 3 步开干

```bash
# ① 装依赖
bash kubernetes/metrics-server/install.sh
bash kubernetes/vpa/install.sh

# ② 全集群批量建 VPA(updateMode: Off,只看建议)
bash kubernetes/vpa/bulk-recommend.sh -A

# ③ 等 24-48 小时,看建议
bash kubernetes/vpa/bulk-recommend.sh -A --dump

# 不要了,一键删(只删本脚本建的)
bash kubernetes/vpa/bulk-recommend.sh -A --cleanup
```

---

# 读建议:把 4 个字段变成 Deployment 模板

## 默认规则一句话

> **requests = Target**(直接抄)+ **memory limit 手设 1.5~2 倍**(VPA 不管)+ **CPU limit 不设或 2~4 倍**(看团队 throttle 容忍度)。Java 例外,limit 按 `-Xmx × 1.3` 算。

```yaml
resources:
  requests:
    cpu: <Target_CPU>             # 直接抄 VPA Target
    memory: <Target_MEM>          # 直接抄 VPA Target
  limits:
    # cpu: 不设(避免 CFS 节流)or requests × 2~4
    memory: <Target_MEM × 1.5~2>  # 手设,VPA 不管
```

## 4 个字段什么意思

| 字段 | 用途 | 用不用 |
|---|---|---|
| **Lower Bound** | 再低就 OOM / 性能差 | **抠成本场景**(CI / batch / dev)允许偶尔 throttle 时用 |
| **Target** ⭐ | VPA 推荐的请求值 | **99% 场景用这个设 requests** |
| **Upper Bound** | 再高就纯浪费 | **不要用它设 requests**,那是 over-provision 极限 |
| Uncapped Target | 没受 `resourcePolicy.minAllowed/maxAllowed` 限制时的原始推荐 | debug 用 — 看 VPA 真实想给多少 |

## 按工作负载分类调整

| 负载类型 | requests 取值 | 为什么 |
|---|---|---|
| **关键路径**(DB / 网关 / 用户面 API) | `Target × 1.2`(留 20% headroom) | 流量突增不能等 HPA,先扛住 |
| **普通业务** Deployment | `Target` | VPA 给的就是 P90 ish,直接用 |
| **后台 / 异步**(消费者 / cronjob) | `Target × 0.8` 或 `Lower Bound + 20%` | OOM 重试可接受,优化密度 |
| **测试 / dev** | `Lower Bound` | 跑得动就行,挤资源 |
| **Java 应用** | **不抄 VPA**,按 `-Xmx × 1.3` 手设 | VPA 看 RSS,JVM 内部 GC heap 它不懂 |

## limits 怎么设 — 跟 VPA 无关

VPA 默认只管 requests,**limits 不要从 VPA 抄**(Upper Bound 是物理上限不是建议)。手设规则:

| 类型 | 建议 | 原因 |
|---|---|---|
| **CPU limit** | **多数情况不设** 或 `requests × 2~4` | CFS 节流引入毛刺,burst 能力被削掉 |
| **Memory limit** | **必须设**,`requests × 1.5~2` | 防内存泄漏吃光节点 |
| **Java Memory limit** | `-Xmx × 1.3`(GC 算法不同 1.2~1.5) | JVM 堆外内存(metaspace / direct buffer / native)算进 RSS |

## 让 VPA 同时调 limit?**不推荐**

```yaml
# 不推荐,只为完整性写一下
spec:
  resourcePolicy:
    containerPolicies:
      - containerName: '*'
        controlledValues: RequestsAndLimits  # 默认 RequestsOnly
```

理由:VPA 调 limit 容易踩 OOM —— 它按使用历史给 limit,但 limit 应该按"容忍度"给。让 VPA 只调 requests,limits 在 Deployment 模板里按 ratio 写死,可控性更好。

---

# 什么时候 VPA 的建议不可信(冷启动信号)

> **看到下面 3 类信号 = 现在不要按这表改模板,等 48 小时再 dump**。

## 信号 1:Target 卡在 VPA 默认 floor

| Target 值 | 意思 |
|---|---|
| **CPU 25m** | `--pod-recommendation-min-cpu-millicores=25` 默认下限 — 样本不够,VPA 退到 floor |
| **CPU 10-12m** | kube-rbac-proxy 这种已经有低 limit 的 sidecar 触到内部 floor |
| **Memory 250Mi** | `--pod-recommendation-min-memory-mb=250` 默认下限 — 同上 |
| **Memory 83Mi** | sidecar 类已有低 limit 跌破 |

**含义**:Target 卡在默认值,不是"你的 Pod 用 25m CPU",是"VPA 不知道,先按下限给"。

## 信号 2:`Lower Bound ≈ Target`

健康 VPA 的 Lower 应该明显低于 Target(常见 1/2 ~ 1/3),代表 P50 和 P90 拉开。Lower = Target 说明采样还没看到负载波动。

## 信号 3:Java 类 Upper Bound 离谱宽

| 应用类 | 典型 Upper Mem | 真实意思 |
|---|---|---|
| Java app / Grafana / Kafka UI / RedisInsight | 10-40 Gi | JVM heap 偶尔摸到 limit ceiling,VPA 直接放大 Upper |

**Java 应用永远不要让 VPA 推 limit**,VPA 对 JVM 完全失能(它看 RSS,JVM 看 heap)。

---

# 实操流程

## 第一轮 dump 之后能立刻做的

| 动作 | 理由 |
|---|---|
| 删测试 Pod(`hello-app` / `otel-demo` 这类) | 没流量,VPA 看不到真实需求 |
| Java 类从 VPA 移出(留着也没用) | VPA 对 JVM 失能 |
| Operator 类(`*-operator` / `kube-state-metrics`)Target 还在 floor 但本身 idle | 可以直接把 requests 降到 100Mi / 25m,reco 信号不可信但 idle 状态本身是真的 |

## 等 48 小时之后再做

| 动作 | 理由 |
|---|---|
| 重 dump,看 Target 是否离开 floor(`50m` `400Mi` 这种才是真实数据) | 8 个有效样本以后 VPA 才会出非默认 reco |
| 看 Lower Bound 是否拉开和 Target 的差距 | 拉开 = 数据有 P50/P90 差异,可信 |
| 长尾负载(8 小时 batch)需要 8 天数据 | VPA 默认半衰期是 24h,8 天足够覆盖 |

## 验证 metrics-server 真在采

```bash
kubectl top pod -A | head -20                                              # 出 CPU/MEM 才算 OK
kubectl -n kube-system logs deploy/vpa-recommender --tail=100 | grep -iE 'samples|checkpoint'   # 看采样累计
```

---

# 排错速查

| 现象 | 原因 + 修 |
|---|---|
| `--dump` 全是 25m/250Mi | 数据没积累,等 24-48h |
| `--dump` 输出空 / `<none>` | metrics-server 没接通,`kubectl top pod <name>` 应该出数,出不来先修它 |
| 个别 VPA `Conditions: NoPodsMatched` | targetRef 写错(name / kind / namespace) |
| 等了 48h 仍 default | `kubectl -n kube-system logs deploy/vpa-recommender --tail=100`,看 metrics-server / Prometheus 是否接通 |
| Pod 还是被 OOMKill | VPA 推 requests 不动 limit,**手设 memory limit** 才能改变 OOM 行为 |

---

# 进阶:Auto 模式 / Goldilocks

| 选项 | 何时用 |
|---|---|
| `install.sh --with-admission` | 真想自动改 Pod requests(VPA 重启 Pod 注入新 requests)。需要 metrics-server + 已知 Pod 不在意短暂重启 |
| Goldilocks operator | 长期常态监控,带 web dashboard,labeled namespace 自动建 VPA |

Goldilocks 装法见上层 `kubernetes/README.md`(以后写)。本目录暂只覆盖 Recommender + bulk-recommend 流程。
