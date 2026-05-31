#!/bin/bash
# 安装 nvidia-container-toolkit, apt 源走 Nexus raw-nvidia 代理(nvidia.github.io).
#
# 适用: Ubuntu / Debian 节点 (containerd 或 docker 已装)
# 后置: 装完后需要配 runtime 用 nvidia, 见末尾提示
#
# 用法:
#   sudo bash install.sh                       # 默认走 Nexus
#   sudo bash install.sh --nexus '<url>'       # 改 Nexus 地址
#   sudo bash install.sh --no-install          # 只写源/key, 不跑 apt install
#   sudo bash install.sh --runtime containerd  # 装完顺手配 runtime (containerd/docker)
set -uo pipefail

NEXUS="https://nexus.ihome.sxxpqp.top:8443/repository/raw-nvidia"
KEYRING="/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"
LIST_FILE="/etc/apt/sources.list.d/nvidia-container-toolkit.list"
DO_INSTALL=true
RUNTIME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --nexus)      NEXUS="$2"; shift 2 ;;
    --no-install) DO_INSTALL=false; shift ;;
    --runtime)    RUNTIME="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

if [ "$(id -u)" != "0" ]; then
  echo "ERROR: 需要 root 或 sudo 执行"
  exit 1
fi

if ! command -v apt-get &>/dev/null; then
  echo "ERROR: 此脚本只支持 apt 系 (Ubuntu/Debian)"
  exit 1
fi

echo "========================================="
echo " nvidia-container-toolkit 安装"
echo "  nexus:    ${NEXUS}"
echo "  keyring:  ${KEYRING}"
echo "  list:     ${LIST_FILE}"
echo "  runtime:  ${RUNTIME:-<不配>}"
echo "========================================="
echo ""

# ---------- 1. 写 gpgkey ----------
echo "[1/3] 拉 gpgkey → ${KEYRING}"
curl -fsSL "${NEXUS}/libnvidia-container/gpgkey" \
  | gpg --dearmor --yes -o "${KEYRING}"
echo "  ✓ keyring 已写入"
echo ""

# ---------- 2. 写 apt 源 ----------
# 原始 list 内容(已核对):
#   deb https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /
#   #deb https://nvidia.github.io/libnvidia-container/experimental/deb/$(ARCH) /
# 处理:
#   - 替换所有 nvidia.github.io URL → Nexus(stable + experimental 都覆盖)
#   - 只给非注释 deb 行加 signed-by
#   - 保留 $(ARCH) 让 apt 自己展开成 amd64/arm64
# 注意: curl|sed|tee 不经 bash 求值, $(ARCH) 会原样落盘
echo "[2/3] 写 ${LIST_FILE} (deb URL 同步重写到 Nexus)"
curl -s -L "${NEXUS}/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
  | sed -e "s#https://nvidia.github.io/libnvidia-container/#${NEXUS}/libnvidia-container/#g" \
        -e "s#^deb #deb [signed-by=${KEYRING}] #" \
  | tee "${LIST_FILE}" >/dev/null
echo "  ✓ list 已写入, 内容:"
sed 's/^/    /' "${LIST_FILE}"
echo ""

# ---------- 3. apt install ----------
if [ "$DO_INSTALL" = true ]; then
  echo "[3/3] apt update + install nvidia-container-toolkit"
  apt-get update
  apt-get install -y nvidia-container-toolkit
  echo "  ✓ 装好"
else
  echo "[3/3] 跳过 apt install (--no-install)"
fi
echo ""

# ---------- 4. (可选) 配 runtime ----------
if [ -n "$RUNTIME" ]; then
  case "$RUNTIME" in
    containerd)
      echo "配 containerd 用 nvidia runtime..."
      nvidia-ctk runtime configure --runtime=containerd
      systemctl restart containerd
      echo "  ✓ containerd 已重启"
      ;;
    docker)
      echo "配 docker 用 nvidia runtime..."
      nvidia-ctk runtime configure --runtime=docker
      systemctl restart docker
      echo "  ✓ docker 已重启"
      ;;
    *)
      echo "WARN: --runtime 只支持 containerd / docker, 你给的: ${RUNTIME}, 跳过"
      ;;
  esac
  echo ""
fi

echo "==============================================================="
echo " ✓ 完成"
echo "==============================================================="
echo ""
echo "验证:"
echo "  nvidia-ctk --version"
echo "  nvidia-smi                # 主机驱动 OK 才能看到 GPU"
echo ""
if [ -z "$RUNTIME" ]; then
  echo "下一步 — 让 runtime 用 nvidia(选一个):"
  echo "  containerd: sudo nvidia-ctk runtime configure --runtime=containerd && sudo systemctl restart containerd"
  echo "  docker:     sudo nvidia-ctk runtime configure --runtime=docker     && sudo systemctl restart docker"
  echo ""
fi
echo "K8s 节点还需要装 nvidia-device-plugin:"
echo "  kubectl apply -f kubernetes/kube-device-plugin/nvidia-device-plugin.yml"
echo ""
echo "containerd 用 nvidia runtime 跑容器测试:"
echo "  sudo ctr image pull docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04"
echo "  sudo ctr run --rm --gpus 0 docker.io/nvidia/cuda:12.4.1-base-ubuntu22.04 test nvidia-smi"
