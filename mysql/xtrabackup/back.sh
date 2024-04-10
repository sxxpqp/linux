#!/bin/bash
#(此处写#!/usr/bin/bash同理 )

#查询xtrabackup是否安装
rpm -qa | grep xtrabackup >/dev/null          #rpm -qa为查看所有已安装的包，用grep过滤出xtrabackup并把结果输出到黑洞；此步骤是为了衔接下一步是否需要安装xtrabackup
# shellcheck disable=SC2181
if [ $? = 0 ]; then                             #$?=0则为查询到会执行then后的操作，若$?!=0则执行else后的操作
    echo "xtrabackup已安装,将为您进行增量备份" >/dev/null #已安装直接略过安装步骤跳出if循环进入下一个if语句即全备中
else
    echo "xtrabackup未安装，将为您安装" #接下来的操作均为安装xtrabackup
    yum -y install wget >/dev/null
    wget https://downloads.percona.com/downloads/Percona-XtraBackup-2.4/Percona-XtraBackup-2.4.27/binary/redhat/7/x86_64/percona-xtrabackup-24-2.4.27-1.el7.x86_64.rpm && rpm -ivh percona-xtrabackup-24-2.4.27-1.el7.x86_64.rpm --nodeps --force
    if [ $? = 0 ]; then
        echo "已为您安装成功"
    else
        echo "请手动安装"
    fi
fi
backupdir=/xtrabackup                             #备份主目录
fullbackupdir=$backupdir/full                     #全量备份目录
incrbackupdir=$backupdir/incr                     #增量备份目录
date_today=$(date "+%Y-%m-%d")                    #今日时间，设置上下两行是为了增备便于操作，简化本应一百多条的代码
date_yesterday=$(date "+%Y-%m-%d" -d '1 day ago') #昨天的时间，此处设置几天前的时间非常灵活，只需把1换成需要的时间即可，此处设置1仅是因为公司每日数据稍大，以防万一
usr="root"                                        #设置你登录MySQL的用户
password="Yuxiao0211."                            #对应的密码，此处密码为天马行空虚构，更换即可
#判断全量备份目录是否存在
if [ ! -d $fullbackupdir ]; then #!为取反，-d为判断目录文件是否存在;扩展：若要判断普通文件用-f;当没有全备目录是执行then之后的命令;若存在则直接跳过全备if语句，进入增备if
    mkdir -p $fullbackupdir      #当没有全备目录是先创建，接着进行全备
    innobackupex -u$usr -p$password $fullbackupdir
    if [ $? -eq 0 ]; then #此if为嵌套语句，为的是判断全备是否完成，方便了解当前状态
        echo "全量备份已完成！"
    else
        echo "全量备份失败了！"
    fi
fi
dir=$(ls $incrbackupdir | wc -l | awk '{print $1}') #跳出全备判断语句，开始此脚本重要部分增备，此行命令是为了判断增备的目录是否存在，以此为基础建立下一步的判断操作
if [ $dir -eq 0 ]; then                             #此步操作不理解可以在终端实验dir反引号的命令，执行一个已存在的目录一个未存在的目录对比执行结果
    mkdir -p $incrbackupdir                         #$dir等于0则说明上述查询的增备目录没有，继而创建增备目录，以全备的文件为基础创建第一个增备，此时的文件用变量date_today（因为没有增备文件，这是第一个，用当天的日期）
    innobackupex -u$usr -p$password --incremental $incrbackupdir/$date_today --incremental-basedir=$fullbackupdir/$(ls $fullbackupdir)
else
    innobackupex -u$usr -p$password --incremental $incrbackupdir/$date_today --incremental-basedir=$incrbackupdir/$(ls $incrbackupdir/$date_yesterday) #$dir不等于0时说明增备文件已经存在，这是需要以上一次的增备文件为基础再次增备，这时date_yesterday就有用处了，因为我要每天增备一次，所以此处的date_yesterday设置的是一天前，视情况而定（注意上下两个命令行的区别，上面是查询的全备文件下面这条则是查询的增备前一天的文件）
fi
if [ $? -eq 0 ]; then #最后的if语句是为了判断增备是否执行成功，基础命令易理解，在这不多赘述
    echo "增量备份已完成"
else
    echo "增量备份失败了！"
fi
