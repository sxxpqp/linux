#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/clash/push_rs.sh
dir=(ls -d */)
for i in ${dir[@]}
do
    echo $i
    cd $i
    cp ../.npmrc .
    npm publish --registry=http://jenkins.zkturing.com:8081/nexus/content/repositories/npm-pubile/
    cd ..
done