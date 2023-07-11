# mysql 上亿条数据批量删除
# 2018-04-26 
1.创建临时表备份数据
CREATE TABLE user_game_log_old SELECT * FROM user_game_log where cts>1619798400000;
2.截断表
TRUNCATE TABLE user_game_log;
3.备份的数据插入到表中
INSERT INTO user_game_log SELECT * FROM user_game_log_old;

# sysctl.conf 出现网络问题
# Path: /etc/sysctl.conf
# 2018-04-26
net.ipv4.tcp_tw_reuse = 1   # 开启重用。允许将TIME-WAIT sockets重新用于新的TCP连接，默认为0，表示关闭
net.ipv4.tcp_tw_recycle = 1 # 开启TCP连接中TIME-WAIT sockets的快速回收，默认为0，表示关闭
net.ipv4.tcp_fin_timeout = 30 # 修改系統默认的 TIMEOUT 时间

