#!/bin/bash
docker build -t harbor.iot.store:8085/turing-kubesphere/clash:v1.0 .
docker push harbor.iot.store:8085/turing-kubesphere/clash:v1.0
