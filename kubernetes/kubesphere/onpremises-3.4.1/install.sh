#!/usr/bin/env bash
# 系统: macOS / Linux 控制机；目标节点为 Linux systemd + containerd
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/kubesphere/onpremises-3.4.1/install.sh
# 用法: 在完整仓库内 bash install.sh --kubeconfig FILE --context NAME --nodes-file FILE [--apply]
set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../../.." && pwd)"
APPLY=false
CONFIG='' CONTEXT='' NODES='' STORAGE='' PASSWORD_FILE=''
TIMEOUT=900s
INSTALLER_SOURCE=docker.io/kubesphere/ks-installer:v3.4.1

# 参数与公共函数
die() { echo "错误: $*" >&2; exit 1; }
usage() {
  cat <<'EOF'
KubeSphere 3.4.1 自建集群安装（全新安装，不升级现有实例）
必填: --kubeconfig FILE --context NAME --nodes-file FILE
可选: --storage-class NAME（默认读取唯一默认 SC）
      --password-file FILE（默认 ~/.kube/ks341-<context>.secret）
      --timeout 900s；--apply（默认仅预检，不写节点/集群）
      --installer-source IMAGE（显式指定可用安装器源，拉取后建立上游名称的本地标签）
节点清单: 每行 Kubernetes节点名 SSH目标，支持 root@IP 或 ~/.ssh/config 别名。
目标要求: Kubernetes 1.20~1.26，amd64，containerd，默认 StorageClass，SSH 免密。
节点须已启用 config_path=/etc/containerd/certs.d；不修改现有 containerd 主配置。
EOF
}
parse_args() {
  while (($#)); do
    case "$1" in
      --help|-h) usage; exit 0 ;;
      --apply) APPLY=true; shift ;;
      --kubeconfig|--context|--nodes-file|--storage-class|--password-file|--timeout|--installer-source)
        (($# >= 2)) || die "$1 缺少值"
        case "$1" in
          --kubeconfig) CONFIG=$2 ;; --context) CONTEXT=$2 ;; --nodes-file) NODES=$2 ;;
          --storage-class) STORAGE=$2 ;; --password-file) PASSWORD_FILE=$2 ;; --timeout) TIMEOUT=$2 ;;
          --installer-source) INSTALLER_SOURCE=$2 ;;
        esac
        shift 2 ;;
      *) die "未知参数 $1" ;;
    esac
  done
}

remote() {
  local target=$1; shift
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$target" \
    'if [ "$(id -u)" = 0 ]; then exec bash -s; else exec sudo -n bash -s; fi' "$@"
}

# 1. 检查集群、已有存储和全部节点连接；此阶段只读。
check_cluster() {
  [[ -r "$CONFIG" && -n "$CONTEXT" && -r "$NODES" ]] || { usage; exit 1; }
  [[ "$TIMEOUT" =~ ^[1-9][0-9]*s$ ]] || die 'timeout 必须为正整数秒，例如 900s'
  [[ "$INSTALLER_SOURCE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]+$ ]] || die '非法安装器镜像引用'
  for tool in kubectl python3 ssh; do command -v "$tool" >/dev/null || die "缺少 $tool"; done
  [[ -r "$MIRRORS" && -r "$TEMPLATE/installer.yaml" && -r "$TEMPLATE/cluster-configuration.yaml" ]] || die '请在完整仓库内执行'
  "${K[@]}" version -o json > "$WORK/version.json"
  "${K[@]}" get nodes -o json > "$WORK/nodes.json"
  "${K[@]}" get storageclasses -o json > "$WORK/storage.json"
  "${K[@]}" get namespace kubesphere-system --ignore-not-found -o name > "$WORK/existing"
  [[ ! -s "$WORK/existing" ]] || die 'kubesphere-system 已存在；本入口只支持全新安装，请用 status/logs 检查现有安装'
  [[ "$("${K[@]}" auth can-i '*' '*' --all-namespaces)" == yes ]] || die '需要 cluster-admin 权限'
  python3 - "$WORK" "$NODES" "$STORAGE" <<'PY'
import json, pathlib, re, sys
w = pathlib.Path(sys.argv[1])
def require(ok, msg):
    if not ok: raise SystemExit(msg)
v = json.loads((w/'version.json').read_text())['serverVersion']['gitVersion']
m = re.match(r'^v1\.(\d+)\.', v)
require(m and 20 <= int(m[1]) <= 26, f'不支持 Kubernetes {v}，KubeSphere 3.4 要求 1.20~1.26')
nodes = json.loads((w/'nodes.json').read_text())['items']
require(nodes, '集群无节点')
inventory = {}
targets = set()
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    line = line.split('#', 1)[0].strip()
    if not line: continue
    fields = line.split()
    require(len(fields) == 2, f'清单每行须为 节点名 SSH目标: {line}')
    name, target = fields
    require(re.fullmatch(r'[a-z0-9][a-z0-9.-]*', name), f'非法节点名 {name}')
    require(re.fullmatch(r'(?:[a-zA-Z0-9_][a-zA-Z0-9_.-]*@)?[a-zA-Z0-9_][a-zA-Z0-9_.-]*', target), f'非法 SSH 目标 {target}')
    require(name not in inventory and target not in targets, '节点/SSH目标重复')
    inventory[name] = target
    targets.add(target)
require(set(inventory) == {n['metadata']['name'] for n in nodes}, '清单必须恰好覆盖全部集群节点（含 master）')
for n in nodes:
    name = n['metadata']['name']
    info = n['status']['nodeInfo']
    require(info['architecture'] == 'amd64' and info['operatingSystem'] == 'linux', f'{name}: 此自建入口仅支持 Linux amd64')
    require(info['containerRuntimeVersion'].startswith('containerd://'), f'{name}: 需要 containerd')
    require(any(c['type']=='Ready' and c['status']=='True' for c in n['status']['conditions']), f'{name}: NotReady')
scs = json.loads((w/'storage.json').read_text())['items']
defaults = [s['metadata']['name'] for s in scs if any(s['metadata'].get('annotations', {}).get(k)=='true' for k in ('storageclass.kubernetes.io/is-default-class', 'storageclass.beta.kubernetes.io/is-default-class'))]
require(len(defaults) == 1, '需要唯一默认 StorageClass；先配置存储，再安装')
sc = sys.argv[3] or defaults[0]
require(sc in {s['metadata']['name'] for s in scs}, f'StorageClass 不存在: {sc}')
require(re.fullmatch(r'[a-z0-9][a-z0-9.-]*', sc), '非法 StorageClass 名称')
(w/'storage').write_text(sc)
(w/'inventory').write_text(''.join(f'{n} {t}\n' for n,t in inventory.items()))
print(f'集群版本: {v}; StorageClass: {sc}; 节点数: {len(nodes)}')
PY
  STORAGE=$(cat "$WORK/storage")
  # 全部节点先只读预检，避免前几个节点写完才发现后续节点不能连接。
  while read -r node target; do
    echo "预检 $node → $target"
    remote "$target" <<'REMOTE' || die "$node 预检失败：检查 SSH/sudo、containerd CRI 和 config_path=/etc/containerd/certs.d"
set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''
for c in systemctl containerd crictl ctr tar; do command -v "$c" >/dev/null; done
systemctl is-active --quiet containerd
containerd config dump | grep -E '^[[:space:]]*config_path = "/etc/containerd/certs.d"' >/dev/null
crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null
test -f /etc/containerd/config.toml
REMOTE
  done < "$WORK/inventory"
}

# 本机生成初始密码并渲染清单，不提交明文密码。
prepare_config() {
  # 只在 apply 时生成密码；保存在仓库外，不输出到日志。
  PASSWORD_FILE=${PASSWORD_FILE:-"$HOME/.kube/ks341-$(printf '%s' "$CONTEXT" | tr -c 'a-zA-Z0-9_.-' '_').secret"}
  python3 - "$PASSWORD_FILE" "$TEMPLATE/cluster-configuration.yaml" "$STORAGE" "$WORK/cluster.yaml" <<'PY'
import json, os, pathlib, re, secrets, sys
p = pathlib.Path(sys.argv[1]).expanduser()
p.parent.mkdir(parents=True, exist_ok=True)
if not p.exists():
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as f: f.write('Ks341-7' + secrets.token_hex(16) + '\n')
if p.stat().st_mode & 0o077: raise SystemExit('密码文件必须 chmod 600')
password = p.read_text().rstrip('\n')
if not (8 <= len(password) <= 64 and all(re.search(x, password) for x in ('[a-z]', '[A-Z]', '[0-9]'))):
    raise SystemExit('密码必须 8~64 字符并包含大小写和数字')
text = pathlib.Path(sys.argv[2]).read_text()
text = text.replace('    storageClass: standard', '    storageClass: ' + sys.argv[3])
text = text.replace('    jwtSecret: ""', '    adminPassword: ' + json.dumps(password) + '\n    jwtSecret: ""')
fd = os.open(sys.argv[4], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f: f.write(text)
PY
}

# 2. 逐台备份并更新镜像源；任意节点失败即停止。
configure_mirrors() {
  while read -r node target; do
    echo "更新镜像源: $node"
    # 先备份，再流式执行仓库中唯一的 mirrors.sh；不复制维护 mirror 映射。
    {
      cat <<'REMOTE'
set -euo pipefail
export SYSTEMD_PAGER='' PAGER=cat SYSTEMD_LESS=''
backup=$(mktemp -d /var/backups/ks341-mirrors.XXXXXXXX)
cp -a /etc/containerd/config.toml "$backup/"
if [ -d /etc/containerd/certs.d ]; then tar -C /etc/containerd -czf "$backup/certs.d.tar.gz" certs.d; fi
echo "镜像源备份: $backup"
REMOTE
      cat "$MIRRORS"
      printf 'INSTALLER_SOURCE=%q\n' "$INSTALLER_SOURCE"
      cat <<'REMOTE'
systemctl restart containerd
systemctl is-active --quiet containerd
crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null
crictl --runtime-endpoint unix:///run/containerd/containerd.sock --image-endpoint unix:///run/containerd/containerd.sock pull "$INSTALLER_SOURCE"
canonical=docker.io/kubesphere/ks-installer:v3.4.1
if [ "$INSTALLER_SOURCE" != "$canonical" ]; then
  # 不覆盖已有本地标签；冲突时报错，由操作者检查镜像来源。
  images=$(ctr --address /run/containerd/containerd.sock -n k8s.io images ls)
  source_id=$(printf '%s\n' "$images" | awk -v ref="$INSTALLER_SOURCE" '$1 == ref {print $3}')
  test -n "$source_id"
  canonical_id=$(printf '%s\n' "$images" | awk -v ref="$canonical" '$1 == ref {print $3}')
  if [ -n "$canonical_id" ]; then
    test "$source_id" = "$canonical_id" || { echo '安装器本地标签已存在且内容不同，停止'; exit 1; }
  else
    ctr --address /run/containerd/containerd.sock -n k8s.io images tag "$INSTALLER_SOURCE" "$canonical"
  fi
fi
REMOTE
    } | remote "$target"
    "${K[@]}" wait --for=condition=Ready "node/$node" --timeout=180s
  done < "$WORK/inventory"
}

# 3. 提交安装清单并等待核心服务就绪。
install_kubesphere() {
  "${K[@]}" apply -f "$TEMPLATE/installer.yaml"
  "${K[@]}" wait --for=condition=Established crd/clusterconfigurations.installer.kubesphere.io --timeout=60s
  "${K[@]}" apply -f "$WORK/cluster.yaml"
  "${K[@]}" -n kubesphere-system wait --for=jsonpath='{.status.core.status}'=enabled clusterconfiguration/ks-installer --timeout="$TIMEOUT"
  for component in ks-apiserver ks-controller-manager ks-console; do
    "${K[@]}" -n kubesphere-system rollout status "deployment/$component" --timeout=180s
  done
  "${K[@]}" -n kubesphere-system get service ks-console
  echo "核心组件已就绪。控制台: http://<可访问的节点IP>:30880；用户 admin；密码文件: $PASSWORD_FILE"
}

# 主流程：检查 → 镜像源 → KubeSphere。默认只检查，--apply 才执行安装。
parse_args "$@"
K=(kubectl --kubeconfig "$CONFIG" --context "$CONTEXT" --request-timeout=30s)
TEMPLATE="$DIR/../kind-3.4.1"
MIRRORS="$ROOT/docker/containerd/mirrors.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo '[1/3] 检查集群、StorageClass 和全部节点'
check_cluster
if ! $APPLY; then
  echo '预检通过。加 --apply 后执行：更新镜像源 → 安装 KubeSphere。'
  exit 0
fi
prepare_config
echo '[2/3] 更新全部节点镜像源并验证安装器拉取'
configure_mirrors
echo '[3/3] 安装 ks-installer 并等待 KubeSphere 就绪'
install_kubesphere
