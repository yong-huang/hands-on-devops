# 派生 Jenkins 镜像：Pipeline + git（共享库经 file:// git 仓加载）
FROM jenkins/jenkins:lts-jdk17
USER root
COPY plugins.txt /tmp/plugins.txt
RUN jenkins-plugin-cli -f /tmp/plugins.txt && rm -f /tmp/plugins.txt
USER jenkins
