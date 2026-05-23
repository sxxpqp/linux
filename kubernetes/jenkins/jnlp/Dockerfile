FROM docker:29.1.5-cli AS docker_cli_downloader
FROM kubesphere/builder-maven:v3.2.1-jdk11
COPY --from=docker_cli_downloader /usr/local/bin/docker /usr/bin/docker



#   docker build -t registry.cn-hangzhou.aliyuncs.com/sxxpqp/builder-maven:v3.2.1-jdk11 .



