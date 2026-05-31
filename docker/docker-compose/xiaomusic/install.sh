#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/docker-compose/xiaomusic/install.sh

# 判断lobe-chat-db文件存在吧
if [ -d "xiaomusic" ]; then
  echo "xiaomusic文件夹已存在"
  cd xiaomusic
else
  mkdir xiaomusic  && cd xiaomusic
fi
curl https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/main/docker/docker-compose/xiaomusic/docker-compose.yaml -o docker-compose.yaml
