FROM  bitnami/java:1.8

RUN ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && echo 'Asia/Shanghai' >/etc/timezone

EXPOSE 4008

ADD turingcloud-safety-biz.jar app.jar
ADD hosts ./

CMD cat hosts >> /etc/hosts;java  -Xms1024m -Xmx1024m -Djava.security.egd=file:/dev/./urandom -jar app.jar