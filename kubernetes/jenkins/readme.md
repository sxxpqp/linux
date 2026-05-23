# 更新地址 https://mirrors.huaweicloud.com/jenkins/updates/update-center.json

# 只有修改配置文件就行

sed -i s#https://updates.jenkins.io/download/#https://nexus.ihome.sxxpqp.top:8443/repository/jenkins/#g /var/jenkins_home/updates/default.json
sed -i s#www.gooole.com#www.baidu.com#g /var/jenkins_home/updates/default.json

# 在重启jenkins 需要看default.json 配置变化了才行
cat /var/jenkins_home/updates/default.json|grep 8443
