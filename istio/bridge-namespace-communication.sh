#!/bin/bash
# 1. 创建bridge sxxpqp
ip link add sxxpqp type bridge
ip link list
# 2. 创建两个veth pair
ip link add sxx type veth peer name pqp
# 3. 将veth pair的一端加入bridge sxxpqp
ip link set sxx master sxxpqp
# 4. 将veth pair的另一端放入namespace pqp
ip netns add pqp
ip link set pqp netns pqp
# 5. 给veth pair的两端分别配置IP地址
ip add add dev sxxpqp 192.168.99.96/24
ip netns exec pqp ip add add dev pqp 192.168.99.69/24
# 6. 启动veth pair的两端
ip link set sxxpqp up
ip netns exec pqp ip link set pqp up