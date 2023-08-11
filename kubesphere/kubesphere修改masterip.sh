### 修改单节点kubesphere的masterip为127.0.0.1
oldip=192.168.1.4
newip=127.0.0.1
#### etcd配置文件修改
```
cp /etc/etcd.env{,.bak}
sed -i "s/$oldip/$newip/g" /etc/etcd.env
```
#### kube-apiserver配置文件修改
```
cp -Rf /etc/kubernetes/ /etc/kubernetes-bak
cd /etc/kubernetes
find . -type f | xargs grep $oldip
find . -type f | xargs sed -i "s/$oldip/$newip/"
find . -type f | xargs grep $newip
```
