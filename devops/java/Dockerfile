FROM pig4cloud/java:8-jre

MAINTAINER wangiegie@gmail.com

ENV TZ=Asia/Shanghai
ENV JAVA_OPTS="-Xms1024m -Xmx1024m -Djava.security.egd=file:/dev/./urandom"

RUN ln -sf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone 

RUN mkdir -p /turingcloud-udp-mandun

WORKDIR /turingcloud-udp-mandun

# EXPOSE 4008
# EXPOSE 14008
EXPOSE 16000
EXPOSE 10000/udp

# ADD ./target/turingcloud-safety-biz.jar ./
COPY  .  .

# CMD java $JAVA_OPTS -jar turingcloud-safety-biz.jar
CMD java $JAVA_OPTS -jar turingcloud-udp-mandun.jar
