#!/bin/bash
mkdir nvidia-packages
# 赋予文件夹可读可写权限（临时调整，方便下载）
sudo chmod +777 nvidia-packages

# 进入文件夹重新执行下载命令（无需 sudo，避免权限问题）
cd nvidia-packages
apt-get download $(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces --no-enhances --no-pre-depends nvidia-container-toolkit | grep "^\w" | sort -u)