#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/clash/update_image.sh
docker build -t harbor.iot.store:8085/turing-kubesphere/clash:v1.0 .
docker push harbor.iot.store:8085/turing-kubesphere/clash:v1.0
