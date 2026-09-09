# =============================================================================
# saltfs/salt/nginx.sls — 声明式状态：nginx 装好、配置正确、进程活着
#
# SLS 三段式：ID 声明 + 状态模块 + 参数。
# 声明"要什么"（nginx 已安装、配置文件内容=模板渲染结果），
# 而不是"怎么做"（对比 shell：apt-get install && cp && reload）。
# requisites（watch/require）表达依赖：配置变了才 reload。
# =============================================================================
nginx packages:
  pkg.installed:
    - name: nginx
    - refresh: true          # 先 apt update，容器镜像的包索引通常是旧的

app config:
  file.managed:
    - name: /etc/nginx/http.d/app.conf
    - source: salt://nginx/app.conf.j2
    - template: jinja        # 模板里可用 grains/pillar
    - makedirs: true         # 父目录不存在时自动创建（否则报 Parent directory not present）
    - mode: '0644'
    # onchanges：只有本状态真的发生变化才触发 cmd（watch_in 在部分版本里会每轮都跑）
    # （cmd 侧用 onchanges 引用本 file）

nginx live:
  # 容器内没有 systemd：reload 失败就冷启动（|| nginx）
  cmd.run:
    - name: nginx -t && (nginx -s reload 2>/dev/null || nginx)
    - onchanges:
      - file: app config
