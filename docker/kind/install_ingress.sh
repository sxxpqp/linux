#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/kind/install_ingress.sh
cd "$(dirname "$0")"
kubectl apply -f ./ingress-nginx.yaml