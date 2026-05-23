#  客户端安装使用
# 创建 /opt/nps 目录存放配置文件
```
mkdir /opt/npc
```
# 拉取 sxxpqp/nps 镜像
```
docker pull sxxpqp/npc
```
# 运行 npc 容器，按提示改好命令，如下图所示
# 唯一验证密钥在管理界面中获取 vkey替换自己的vkey 特权模式
```
docker run -d --name=npc --restart=always --net=host --privileged dockerproxy.com/sxxpqp/npc -server=clash.sxxpqp.top:8024 -vkey=2ei9nzadu1o2tzwt
```


# 查看日志
```
docker logs npc
```
