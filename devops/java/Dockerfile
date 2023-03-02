FROM pig4cloud/java:8-jre

MAINTAINER wangiegie@gmail.com

ENV TZ=Asia/Shanghai
ENV JAVA_OPTS="-Xms1024m -Xmx1024m -Djava.security.egd=file:/dev/./urandom"

RUN ln -sf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && mkdir -p /turingcloud-auth

RUN mkdir -p /turingcloud-safety-biz

WORKDIR /turingcloud-safety-biz

EXPOSE 4008
EXPOSE 14008

ADD ./target/turingcloud-safety-biz.jar ./

CMD java $JAVA_OPTS -jar turingcloud-safety-biz.jar
