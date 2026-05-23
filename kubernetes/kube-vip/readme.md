export VIP=192.168.215.200 # 我的vip是192.168.215.200
export INTERFACE=ens33 #可以用 ip a 查看接口名称
# kube-vip最新镜像为v0.8.0,但我装时无法成功，后来降到v0.7.2后安装成功了
ctr image pull docker.io/plndr/kube-vip:v0.7.2
ctr run --rm --net-host docker.io/plndr/kube-vip:v0.7.2 vip /kube-vip manifest pod \
--interface $INTERFACE \
--vip $VIP \
--controlplane \
--services \
--arp \
--leaderElection | tee  /etc/kubernetes/manifests/kube-vip.yaml



# 所有控制节点 /etc/kubernetes/manifests/kube-vip.yaml