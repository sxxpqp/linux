#!/bin/bash
# 批量替换 chfs 脚本/配置路径为 Nexus 地址
# 大文件(二进制/tar.gz/rpm等)保留 chfs,只更新 shared/docker/→shared/linux/docker/
# 用法: cd /opt/chfs/data && bash linux/centos/nexusify.sh

set -e

NEXUS="https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main"
DRY_RUN=false

[ "$1" = "--dry-run" ] && DRY_RUN=true

echo "===== Nexus 化: 替换 chfs 脚本路径为 Nexus 代理 ====="
echo ""

# ============ 1. k8s 相关 (shared/k8s/ → linux/kubernetes/) ============
echo "--- k8s ---"
FILES=(
  "linux/kubernetes/csi-driver-nfs/installcsi-nfs.sh"
  "linux/kubernetes/csi-driver-nfs-aliyun/installcsi-nfs.sh"
  "linux/kubernetes/kubeadm/restorandchangevip/readme.md"
  "linux/kubernetes/kubeadm/restore/read.md"
  "linux/kubernetes/kubeblocks/install.sh"
  "linux/kubernetes/kubeblocks/install-snapshotter.sh"
)
for f in "${FILES[@]}"; do
  [ ! -f "$f" ] && continue
  if [ "$DRY_RUN" = true ]; then
    echo "  📄 $f"
    grep -n "chfs.*shared/k8s" "$f"
  else
    sed -i "s|https://chfs.sxxpqp.top:8443/chfs/shared/k8s/|${NEXUS}/linux/kubernetes/|g" "$f"
    echo "  ✅ $f"
  fi
done

# ============ 2. centos 相关 (shared/centos/ → linux/centos/) ============
echo ""
echo "--- centos ---"
FILES=(
  "linux/centos/7/changeyum.sh"
  "linux/centos/changeyum.sh"
  "linux/centos/7/upgradekernel.sh"
  "linux/centos/upgradekernel.sh"
)
for f in "${FILES[@]}"; do
  [ ! -f "$f" ] && continue
  if [ "$DRY_RUN" = true ]; then
    echo "  📄 $f"
    grep -n "chfs.*shared/centos" "$f"
  else
    # 只替换 .repo / .sh 等脚本引用,保留 kernel rpm 二进制引用
    sed -i "/\.rpm/! s|https://chfs.sxxpqp.top:8443/chfs/shared/centos/|${NEXUS}/linux/centos/|g" "$f"
    echo "  ✅ $f"
  fi
done

# ============ 3. itools 相关 ============
echo ""
echo "--- itools ---"
FILES=(
  "itools.sh"
  "itools/kkinstall.sh"
  "linux/centos/nexusify.sh"
)
for f in "${FILES[@]}"; do
  [ ! -f "$f" ] && continue
  if [ "$DRY_RUN" = true ]; then
    echo "  📄 $f"
    grep -n "chfs.*shared/itools" "$f"
  else
    # itools.sh 中的 TOOL_URL 是一个目录前缀,保留结构
    # itools/kkinstall.sh 中是下载 kk 二进制文件,应该保留 chfs
    # 只替换脚本引用
    echo "  ⏭️  $f (itools 二进制下载保留 chfs)"
  fi
done

# ============ 4. docker 脚本 (未改完的) ============
echo ""
echo "--- docker 残留 ---"
FILES=(
  "docker/win/wsl.md"
)
for f in "${FILES[@]}"; do
  [ ! -f "$f" ] && continue
  if [ "$DRY_RUN" = true ]; then
    echo "  📄 $f"
    grep -n "chfs.*shared/docker" "$f"
  else
    sed -i "s|https://chfs.sxxpqp.top:8443/chfs/shared/docker/|${NEXUS}/linux/docker/|g" "$f"
    echo "  ✅ $f"
  fi
done

# ============ 5. 还在根目录的 centos 脚本 ============
echo ""
echo "--- 根目录 centos 残留 ---"
FILES=(
  "centos/7/changeyum.sh"
  "centos/7/upgradekernel.sh"
)
for f in "${FILES[@]}"; do
  [ ! -f "$f" ] && continue
  if [ "$DRY_RUN" = true ]; then
    echo "  📄 $f"
    grep -n "chfs.*shared/centos" "$f"
  else
    sed -i "/\.rpm/! s|https://chfs.sxxpqp.top:8443/chfs/shared/centos/|${NEXUS}/linux/centos/|g" "$f"
    echo "  ✅ $f"
  fi
done

# ============ 6. docker-ce 官方源→阿里云 ============
echo ""
echo "--- download.docker.com → mirrors.aliyun.com ---"
FILES=(
  "linux/kubernetes/v1.23.6-CentOS-binary-install.md"
  "linux/kubernetes/learn/v1.23.6-CentOS-binary-install.md"
)
for f in "${FILES[@]}"; do
  [ ! -f "$f" ] && continue
  if [ "$DRY_RUN" = true ]; then
    echo "  📄 $f"
    grep -n "download\.docker\.com" "$f"
  else
    # 只改 docker-ce.repo 下载源,不改二进制包下载地址(那些需要保持原样作为文档)
    sed -i "s|https://download.docker.com/linux/centos/docker-ce.repo|https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo|g" "$f"
    echo "  ✅ $f"
  fi
done

echo ""
echo "===== 完成 ====="
echo "剩余需手动确认的:"
grep -rn "chfs\.sxxpqp" . --include="*.sh" --include="*.md" 2>/dev/null | grep -v ".git" | grep -v "\.tar\.gz\|\.tgz\|\.zip\|\.rpm\|\.deb\|\.jar\|runc\.amd64" | grep -v "nexusify\|shared/linux" || echo "  (无)"
