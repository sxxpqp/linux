#!/bin/bash
# 下载: https://nexus.ihome.sxxpqp.top:8443/repository/raw-githubusercontent/sxxpqp/linux/refs/heads/main/kubernetes/jenkins/change-plugin.sh
# Jenkins 国内镜像源自动配置脚本 - K8s 环境专用修复版

declare -A dict
jenkins_mirrors=("mirrors.huaweicloud.com" "mirrors.tuna.tsinghua.edu.cn" "mirrors.ustc.edu.cn" "mirrors.cloud.tencent.com")

echo "正在扫描可用源..."

# 1. 探测可用性
available_mirrors=()
for mirror in "${jenkins_mirrors[@]}"; do
    if curl -o /dev/null -s -m 3 -I -L "https://${mirror}/jenkins/updates/update-center.json"; then
        available_mirrors+=("${mirror}")
    fi
done

if [ ${#available_mirrors[@]} -eq 0 ]; then
    echo "错误: 未能探测到可用镜像源，请检查 K8s 网络。"
    exit 1
fi

echo "检测到以下可用源，请选择序号:"
select mirror_host in "${available_mirrors[@]}"; do
    if [[ -n $mirror_host ]]; then break; fi
done

# 2. 定义目标 URL
update_center_url="https://${mirror_host}/jenkins/updates/update-center.json"

# 3. 定位 Jenkins 目录
read -p "输入 Jenkins 系统配置目录 (默认 /var/jenkins_home): " jenkins_home
jenkins_home=${jenkins_home:-/var/jenkins_home}

default_json="${jenkins_home}/updates/default.json"
update_center_xml="${jenkins_home}/hudson.model.UpdateCenter.xml"

echo "--------------------------------------"

echo "更新$default_json"
sed -i "s#updates.jenkins.io/download#${mirror_host}/jenkins#g" $default_json
sed -i 's#www.google.com#www.baidu.com#g'  $default_json

echo "更新$update_center_xml"
sed -i "s#https://updates.jenkins.io/update-center.json#${update_center_url}#g" $update_center_xml
echo "--------------------------------------"
echo "配置完成！请重启 Jenkins 或在管理界面刷新获取。"
