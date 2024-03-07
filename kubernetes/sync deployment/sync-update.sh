#!/bin/bash
# 修改k8s命名空间deployment的容器的镜像
#读取多行deployment.name=镜像名
# namespace=tmc-v2-saas saas线上环境
# namespace=yun-cabrfire-com
# namespace=xiaofangpingtai
# namespace=tmc-v2-saas
# namespace=zhihuixiaofnag
# namespace=shanxihuadian 
# namespace=yuanweimin 
# namespace=zigong-xiaofang
# namespace=zhengshangpinganjia
# namespace=diyishifan
# namespace=guizhoujianyuan
# namespace=zhongyingyun
# namespace=tmc-v2-saas
# namespace=jiaokeyuan-tezhijia
# namespace=hubeiyiweihui
# namespace=jinanyizhuan-zhihuixiaofang
# namespace=shanxihuadian
# namespace=jinzhongshiyuciquxiaofangjiuyuandadui
# namespace=shanxihainayuanqu
# namespace=jinzhongshiyuciquxiaofangjiuyuandadui
# namespace=zhengshang
# namespace=guizhoujianyuan
# namespace=dangyangmingniu-tezhijia
# namespace=diyishifan
# namespace=tmc-v2-saas
# namespace=yuanweimin
# namespace=jinanyizhuan-zhihuixiaofang

# namespace=shanxihainayuanqu
# namespace=mengniuningxia
# namespace=jinzhongshiyuciquxiaofangjiuyuandadui
# namespace=zhengshangpinganjia
# namespace=guizhoujianyuan

# namespace=jinanyizhuan-zhihuixiaofang
# namespace=huli-guizhouzhishengwangluokeji
# namespace=jinanyizhuan-zhihuixiaofang
# namespace=hengyangshizhengxiangqumingzhengju
# namespace=wuhanjingyuan
# 
# namespace=guizhoujianyuan
# namespace=mengniuningxia
# namespace=tmc-v2-saas
# namespace=henanzhongyiyuanfushudisanyiyuan
# namespace=hebeibosi-beimingdingyun
namespace=hebeibosi-beimingdingyun
if [ -z "$namespace" ]
then
  echo "namespace is null"
  exit 1
fi
cat<<EOF > image.txt
turingcloud-activiti=harbor.iot.store:8085/turing-kubesphere/turingcloud-activiti:SNAPSHOT-20
turingcloud-aircraft=harbor.iot.store:8085/turing-kubesphere/turingcloud-aircraft:SNAPSHOT-23
turingcloud-auth=harbor.iot.store:8085/turing-kubesphere/turingcloud-auth:SNAPSHOT-48
turingcloud-daemon-quartz=harbor.iot.store:8085/turing-kubesphere/turingcloud-daemon-quartz:SNAPSHOT-54
turingcloud-daily=harbor.iot.store:8085/turing-kubesphere/turingcloud-daily:SNAPSHOT-284
turingcloud-data=harbor.iot.store:8085/turing-kubesphere/turingcloud-data:SNAPSHOT-62
turingcloud-dataanalysis=harbor.iot.store:8085/turing-kubesphere/turingcloud-dataanalysis:SNAPSHOT-335
turingcloud-device=harbor.iot.store:8085/turing-kubesphere/turingcloud-device:SNAPSHOT-1012
turingcloud-gateway=harbor.iot.store:8085/turing-kubesphere/turingcloud-gateway:SNAPSHOT-23
turingcloud-ground-pressure=harbor.iot.store:8085/turing-kubesphere/turingcloud-ground-pressure:SNAPSHOT-148
turingcloud-light=harbor.iot.store:8085/turing-kubesphere/turingcloud-light:SNAPSHOT-8
turingcloud-register=harbor.iot.store:8085/turing-kubesphere/turingcloud-register:latest
turingcloud-safety=harbor.iot.store:8085/turing-kubesphere/turingcloud-safety:SNAPSHOT-101
turingcloud-tx-manager=harbor.iot.store:8085/turing-kubesphere/turingcloud-tx-manager:latest
turingcloud-upms=harbor.iot.store:8085/turing-kubesphere/turingcloud-upms:SNAPSHOT-673
turingcloud-video=harbor.iot.store:8085/turing-kubesphere/turingcloud-video:SNAPSHOT-451
turingcloud-visual=harbor.iot.store:8085/turing-kubesphere/turingcloud-visual:SNAPSHOT-23
turingcloud-web=harbor.iot.store:8085/turing-kubesphere/turingcloud-web-zktl:SNAPSHOT-1596
EOF
# 通过输入参数获取deployment.name=镜像名
# shellcheck disable=SC2162
while read line
do
  app=$(echo "$line" | awk -F '=' '{print $1}')
  image=$(echo "$line" | awk -F '=' '{print $2}')
  echo "app=$app"
  echo "image=$image"
#   Error: flags cannot be placed before plugin name: -n
#   kubectl set image deployment/$app $app=$image -n ${namespace}
    # shellcheck disable=SC2086
    kubectl set image deployment/$app $app=$image --namespace=${namespace}
done < image.txt






# CPU: 2*4314  16C 2.4G 
# 内存: 2*32G DDR4  
# 硬盘: 2*600G SSD ,9440-8I RAID 0.1.5
# 网口:2*GE+ 2*10GE
# 电源:  2*550W 冗余电源
# location /vrw/ {
        
#        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
#        proxy_set_header X-Forwarded-Proto $scheme;
 
#        proxy_connect_timeout 300;
#        # Default is HTTP/1, keepalive is only enabled in HTTP/1.1
#        proxy_http_version 1.1;
#        proxy_set_header Connection "";
#        chunked_transfer_encoding off; 
#        # minio 服务直连地址
#        proxy_pass  http://turingclou-minio:9199;
# }
# externalIPs:
# - 192.168.0.1
# set -i 's#/:9000/#:9000/vrw/#g' /etc/nginx/nginx.conf


# kill python process
# ps -ef | grep python | grep -v grep | awk '{print $2}' | xargs kill -9





#xm vncviewer external vncviewer missing or not in the path 
# sudo apt-get install vncviewer
# sudo apt-get install vnc4server
# sudo apt-get install vnc4server-core
# sudo apt-get install vnc4server-x11
# sudo apt-get install vnc4server-tightvnc
# sudo apt-get install vnc4server-tigervnc
# sudo apt-get install vnc4server-xvnc4
# tdengine