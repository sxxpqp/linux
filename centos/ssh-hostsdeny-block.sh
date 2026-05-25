#!/usr/bin/bash
# -*- coding:UTF-8 -*-
#
#########################################################
#                                                       #
#    file name: ssh_login_failed_host_deny              #
#  description: 将SSH多次登录失败的IP加入黑名单           #
#       author: sxxpqp                                  #
#      version: 0.1                                     #	
#         date: 2022-04-19                              #
#                                                       #
#########################################################


# 通过lastb获取登录失败的IP及登录失败的次数
lastb | awk '{print $3}' | grep ^[0-9] | sort | uniq -c | awk '{print $1"\t"$2}' > /tmp/host_list
list=`cat /tmp/host_list`
line=`wc -l /tmp/host_list | awk '{print $1}'`
count=1

# 如果/tmp/host_list中有数据，循环至少需要执行一次
while [[ "$line" -ge "$count" ]]; do
	ip_add=`echo $list | awk '{FS="\t"} {print $2}'`
	num=`echo $list | awk  '{FS="\t"} {print $1}'`
#   登录失败达到5次就将该IP写入文件
	if [[ "$num" -ge 5 ]]; then
		grep "$ip_add" /etc/hosts.deny &> /dev/null
		if [[ "$?" -gt 0 ]]; then
# --------> 此处添加当前系统时间，请根据实际情况定义日期格式
			echo "# $(date +%F' '%H:%M:%S)" >> /etc/hosts.deny
			echo "sshd:$ip_add" >> /etc/hosts.deny
		fi
	fi
	let count+=1
#   删除已经写入文件的IP
	sed -i '1d' /tmp/host_list
#   修改$list变量
	list=`cat /tmp/host_list`
done
# 清空临时文件
echo '' > /tmp/host_list
exit 0
