#!/bin/bash
#这里可替换为你自己的执行程序，其他代码无需更改
APP_NAME=kt-ansys-interactive-biz.jar

#使用说明，用来提示输入参数
usage() {
 echo "Usage: sh 脚本名.sh [start|stop|restart|status]"
 exit 1
}

#检查程序是否在运行
is_exist(){
 pid=`ps -ef|grep $APP_NAME|grep -v grep|awk '{print $2}' `
 #如果不存在返回1，存在返回0
 if [ -z "${pid}" ]; then
 return 1
 else
 return 0
 fi
}

#启动方法
start(){
 is_exist
 if [ $? -eq "0" ]; then
 echo "${APP_NAME} is already running. pid=${pid} ."
 else
 nohup java -server -Xms3072M -Xmx3072M -Xmn2048M -Xss1M -XX:SurvivorRatio=8 -XX:MaxTenuringThreshold=5 -XX:PretenureSizeThreshold=1M -XX:+UseParNewGC -XX:+UseConcMarkSweepGC -jar /root/turing_service/kt-ansys-interactive/kt-ansys-interactive-biz/target/kt-ansys-interactive-biz.jar > /root/turing_service/kt-ansys-interactive/kt-ansys-interactive-biz/target/kt-ansys-interactive-biz.log 2>&1 &
check(){
 echo "${APP_NAME} start success"
 fi
}

#停止方法
stop(){
 is_exist
 if [ $? -eq "0" ]; then
 kill -9 $pid
 else
 echo "${APP_NAME} is not running"
 fi
}

#输出运行状态
status(){
 is_exist
 if [ $? -eq "0" ]; then
 echo "${APP_NAME} is running. Pid is ${pid}"
 else
 echo "${APP_NAME} is NOT running."
 fi
}
#检查程序没有运行则启动
check(){
#检查register程序是否在运行
if curl -i http://localhost:8848/nacos | grep 'HTTP/1.1 302' > /dev/null 2>&1
then
echo "nacos is running"

 is_exist
 if [ $? -eq "0" ]; then
 echo "${APP_NAME} is running. Pid is ${pid}"
 else
 echo "${APP_NAME} is NOT running."
 start
 fi
else
echo "nacos is not running"
fi
} 
#重启
restart(){
 stop
 start
}
 
#根据输入参数，选择执行对应方法，不输入则执行使用说明
case "$1" in
 "start")
 start
 ;;
 "stop")
 stop
 ;;
 "status")
 status
 ;;
 "restart")
 restart
 ;;
 "check")
 check
 ;;
 *)
 usage
 ;;
esac