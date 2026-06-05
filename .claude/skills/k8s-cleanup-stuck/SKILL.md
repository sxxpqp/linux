---
name: k8s-cleanup-stuck
description: Diagnose and safely clean up stuck Kubernetes resources — Terminating CR/namespace, RBAC residuals after operator removal, dead admission webhooks silently blocking API. Use when user mentions 卡 Terminating, kubectl delete 卡住, 卸载残留, RBAC forbidden, webhook 拦 API, namespace 删不掉, finalizer 卡, operator 没清干净, calico/cilium/cert-manager 卸载. Provides ordered diagnosis (CR → ns → ClusterRole → webhook), strip-finalizer-first patterns, operator-managed RBAC cleanup, and immediate unstick commands.
---

# K8s 卡死 / 残留清理

> 来自实战:operator 模式 Calico 卸载 → 重装翻车,逐项 debug 出来的完整 playbook。

## 核心思路

K8s 资源卡 Terminating / 删不掉 / 删完又回来,本质就 4 类原因。**按顺序排查**,排错一类就解一类:

| 优先级 | 症状 | 根因类 | 解套动作 |
|---|---|---|---|
| 1 | `kubectl delete` 阻塞 60s+ 才超时 | finalizer 卡(controller 已死或卡住) | **先 `kubectl patch xxx -p '{"metadata":{"finalizers":null}}'` 再 delete** |
| 2 | 删完 `kubectl get` 还在,timestamp 不变 | 控制器(operator/webhook)在边删边建 / 静默拦 | 先关控制器(scale 0 或 delete deploy)、删 webhook |
| 3 | `kubectl delete` 显示 "deleted",资源真没了,但相关 Pod RBAC forbidden | operator 动态创建的 ClusterRole 删了没人重建 | 显式 `kubectl delete clusterrole,clusterrolebinding xxx yyy` |
| 4 | 装 / 改任何东西都失败,错误信息奇怪 | 残留 admission webhook 后端死了,在静默拦 | `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \| grep <component>` 全清 |

## 快速诊断决策树

```
kubectl delete X 卡住 / 不生效
  │
  ├─ X 是 CR(Installation/IPPool 等)?
  │   └─ kubectl get X -o yaml | grep -A3 finalizers
  │      → 有 finalizer:patch 剥掉再 delete
  │
  ├─ X 是 namespace?
  │   └─ kubectl get ns X -o jsonpath='{.status.phase}'
  │      → Terminating:
  │         kubectl get ns X -o json | python3 -c "import sys,json; \
  │           d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" | \
  │           kubectl replace --raw "/api/v1/namespaces/X/finalize" -f -
  │
  ├─ 删完又回来,timestamp 没变?
  │   └─ → "deleted" 是假象,API 实际拒绝
  │      ① 找控制器:kubectl get deploy -A | grep <component>-operator,scale 0 或删
  │      ② 找 webhook:kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations | grep <component>,全删
  │      ③ 再 delete
  │
  └─ 相关 Pod 起来 RBAC forbidden,但 RBAC 文件里看着对?
      └─ → operator 动态创建的 ClusterRole 没被覆盖
         kubectl get clusterrole <pod-sa-name> -o yaml | grep <missing-rule>
         没的话:kubectl delete clusterrole,clusterrolebinding <name> → 让 operator 重建
```

## 正确的卸载顺序(operator 类)

**不要**:删 CR → 删 namespace → 删 operator deployment。这条路线会留下 RBAC + webhook 孤儿,下次装会翻车。

**应该**(每一步删除之前都先剥 finalizer):

```bash
COMPONENT=tigera-operator   # 换成你的:cilium / cert-manager-operator 等
NS=tigera-operator
CALICO_SYSTEM_NS=calico-system   # operator-managed namespace

# 1. 剥 CR finalizer → 删 CR
for cr in apiserver installation; do   # 换成你的 CR 类型
  kubectl patch $cr default --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null
  kubectl delete $cr default --ignore-not-found --timeout=30s
done

# 2. 剥 operator-managed namespace finalizer → 等清空
kubectl get ns $CALICO_SYSTEM_NS -o json 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" | \
  kubectl replace --raw "/api/v1/namespaces/$CALICO_SYSTEM_NS/finalize" -f - 2>/dev/null || true

# 3. 先 scale operator deployment 到 0(防止后续清 RBAC 时被边删边建)
kubectl -n $NS scale deploy $COMPONENT --replicas=0 --timeout=30s 2>/dev/null

# 4. 删 webhook(关键!后端要死之前先删,否则之后 API 全被静默拦)
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null \
  | grep -iE 'calico|tigera|operator' | xargs -r kubectl delete --wait=false

# 5. 反向 delete operator yaml(带走 ns + RBAC + CRDs)
kubectl delete -f <operator.yaml> --ignore-not-found --timeout=180s

# 6. 显式清 operator 动态创建的 cluster-scoped RBAC
kubectl delete clusterrole,clusterrolebinding \
  calico-kube-controllers calico-node calico-cni-plugin \
  --ignore-not-found --wait=false 2>/dev/null

# 7. 兜底剥 operator namespace finalizer
kubectl get ns $NS -o json 2>/dev/null | \
  python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" | \
  kubectl replace --raw "/api/v1/namespaces/$NS/finalize" -f - 2>/dev/null || true
kubectl delete ns $NS --ignore-not-found --timeout=30s
```

## 重装前的 preflight 检查

装之前必跑,挂一项就直接 exit 不让继续:

```bash
# A. Terminating 状态拒绝重装(apply 会变 "configured" 而非 "created",形成 zombie)
for cr in installation apiserver; do
  if kubectl get $cr default -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null | grep -q .; then
    echo "✗ $cr/default 正在 Terminating,先清"; exit 1
  fi
done
for ns in calico-system tigera-operator; do
  if kubectl get ns $ns -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Terminating; then
    echo "✗ ns/$ns Terminating,先清"; exit 1
  fi
done

# B. 残留 ClusterRole 没 ns:operator 不会强覆盖
for r in calico-kube-controllers calico-node calico-cni-plugin; do
  if kubectl get clusterrole $r >/dev/null 2>&1 && ! kubectl get ns tigera-operator >/dev/null 2>&1; then
    echo "⚠ clusterrole/$r 残留,先 delete"
  fi
done

# C. 残留 webhook:最致命,会让后续 API 调用诡异失败
STALE_WH=$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name 2>/dev/null \
  | grep -iE 'calico|tigera|operator')
[ -n "$STALE_WH" ] && { echo "✗ 残留 webhook(必须清):"; echo "$STALE_WH"; exit 1; }
```

## 反模式 — 别这么干

| ✗ 错的做法 | 为什么错 | ✓ 正确做法 |
|---|---|---|
| `kubectl delete X --timeout=300s` 不剥 finalizer 干等 | 等到天黑也没人来清 | 先 patch finalizers:null 再 delete |
| 先 delete operator,再清 CR | CR finalizer 没人处理 → 卡死 | 先删 CR(剥 finalizer),再删 operator |
| 装之前不检查 Terminating | apply 变 "configured" zombie,RBAC 不会重建 | preflight 拒绝在 Terminating 上 apply |
| 删 ClusterRole 不删 binding | binding 引用悬空,虽不报错但残留 | 一起删 |
| `kubectl delete --wait=true`(默认)删 RBAC | RBAC 删除是同步 API,但 wait 偶尔卡 watch | `--wait=false` |

## 调试技巧

```bash
# 1. 看 delete 到底有没有发出去
kubectl delete X -v=9 2>&1 | grep -E 'DELETE|response|status' | tail -20

# 2. 看 ClusterRole 是谁管理的(找出谁会重建它)
kubectl get clusterrole X -o yaml | grep -A5 managedFields

# 3. 看 ownerReferences(级联删除的源头)
kubectl get X -o jsonpath='{.metadata.ownerReferences}'

# 4. 看 webhook 实际拦了什么
kubectl get validatingwebhookconfiguration <name> -o yaml | yq '.webhooks[] | .rules'
```

## 何时调用此 skill

- 用户说"卡 Terminating"、"namespace 删不掉"、"kubectl delete 卡了几分钟"
- 用户说"卸载 X 后重装失败 / RBAC forbidden / webhook 报错"
- 用户说"operator 卸载残留 / 没清干净"
- 用户贴出 `Warning: Detected changes to resource X which is currently being deleted`
- 用户贴出 `failed calling webhook ... no endpoints available`
