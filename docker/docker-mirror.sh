#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/docker-mirror.sh
# Docker 镜像加速配置 + insecure-registries
# 用法: bash docker-mirror.sh

set -e

DOCKER_CONF="/etc/docker/daemon.json"

# 目录不存在则创建
mkdir -p "$(dirname "${DOCKER_CONF}")"

# 备份旧配置
if [ -f "${DOCKER_CONF}" ]; then
  cp "${DOCKER_CONF}" "${DOCKER_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  echo "  ✓ 备份旧配置到 ${DOCKER_CONF}.bak.*"
fi

cat > "${DOCKER_CONF}" << JSON
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "registry-mirrors": ["https://huball.ihome.sxxpqp.top:8443"],
  "insecure-registries": [
    "huball.ihome.sxxpqp.top:8443",
    "ghcr.ihome.sxxpqp.top:8443",
    "quay.ihome.sxxpqp.top:8443",
    "k8s.ihome.sxxpqp.top:8443"
  ],
  "max-concurrent-downloads": 10,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "5"
  }
}
JSON

echo "  ✓ 写入 ${DOCKER_CONF}"

systemctl daemon-reload
systemctl restart docker

echo "  ✓ docker 已重启, 镜像加速生效"
echo ""
echo "验证:"
echo "  docker info | grep -A2 'Registry Mirrors'"
echo "  docker info | grep -A5 'Insecure Registries'"
