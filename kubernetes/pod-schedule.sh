#!/bin/bash
#获取node名称
kubectl get node|grep worker |gawk -F" " '{ print $1 }'>nodes

for node in $(cat nodes)
do 
#获取node的cpu使用率
cpu=$(kubectl top node $node |gawk -F" " '{ print $3 }'|tail -n 1|gawk -F"%" '{ print $1 }')
#获取node的memory使用率
memory=$(kubectl top node $node |gawk -F" " '{ print $5 }'|tail -n 1|gawk -F"%" '{ print $1 }')
if [ $cpu -gt 85 ]
then
    kubectl taint node $node cm=90:NoSchedule
elif [ $memory -gt 85 ]
then
    kubectl taint node $node  cm=90:NoSchedule
else
    kubectl describe node $node |grep -i "cm=90"
    if [ $? -eq 0 ]
    then
    kubectl taint node $node  cm=90:NoSchedule- 
fi
fi
done
### 设置定时任务15分钟执行一次
# crontab -e
#*/15 * * * * /bin/bash /root/kubernetes/node-schedule.sh