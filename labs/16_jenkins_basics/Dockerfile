# 派生 Jenkins 镜像：预装 Pipeline 插件
# 坑：基础镜像默认 USER jenkins，无权限写 /usr/share/jenkins/ref/plugins——
#     插件安装需要临时提权，装完恢复
FROM jenkins/jenkins:lts-jdk17
USER root
COPY plugins.txt /tmp/plugins.txt
RUN jenkins-plugin-cli -f /tmp/plugins.txt && rm -f /tmp/plugins.txt
USER jenkins
