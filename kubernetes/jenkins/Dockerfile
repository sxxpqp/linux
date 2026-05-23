FROM docker:29.1.5-cli AS docker_cli_downloader
FROM jenkins/inbound-agent:latest-jdk21
COPY --from=docker_cli_downloader /usr/local/bin/docker /usr/bin/docker
COPY  kubectl /usr/bin/kubectl
COPY envsubst /usr/bin/envsubst


# registry.cn-hangzhou.aliyuncs.com/sxxpqp/jnlp:jdk21


# docker build -t registry.cn-hangzhou.aliyuncs.com/sxxpqp/jnlp:jdk21 .