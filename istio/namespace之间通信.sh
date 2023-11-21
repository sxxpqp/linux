#!/bin/bash
# 1. 创建两个namespace
ip netns add sxx
ip netns add pqp
ip netns list
# 2. 创建两个veth pair
ip link add sxx type veth peer name pqp
ip link list
# 3. 将veth pair的一端分别放入两个namespace
ip link set sxx netns sxx
ip link set pqp netns pqp

ip netns exec sxx ip link
ip netns exec pqp ip link
# 4. 给veth pair的两端分别配置IP地址
ip netn exec sxx ip add add dev sxx 192.168.88.96/24
ip netn exec pqp ip add add dev pqp 192.168.88.69/24
# 5. 启动veth pair的两端
ip netn exec sxx ip link set sxx up
ip netn exec sxx ip link set pqp up
ip netn exec pqp ip link set pqp up
# 6. 验证两个namespace之间是否可以通信 
ip netn exec sxx ip link set lo up
ip netn exec pqp ip link set lo up
ip netn exec sxx ping 192.168.88.96
ip netn exec sxx ping 192.168.88.69
