#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/docker/getname.sh
# 简洁版：直接通过 -p 选项显示提示并读取输入
read -p "请输入你的名字：" name
echo "你好，$name！"