# =============================================================================
# manifests/webapp.pp — Puppet DSL：class + resource 声明
#
# Puppet 是"声明式 DSL"的原型机（2005 年起）：资源类型 + 属性 + 依赖箭头。
# 对比 Chef 的 Ruby 全语言：Puppet DSL 受限但统一——看一眼就知道改什么。
#
# 资源对应关系（四代对照）：
#   package  ≈ Chef package   ≈ Salt pkg.installed  ≈ Ansible apt 模块
#   file     ≈ Chef template ≈ Salt file.managed   ≈ Ansible template
#   exec     ≈ Chef execute  ≈ Salt cmd.run        ≈ Ansible command
#   ->       依赖箭头：配置就绪后才启动（≈ require/notify/subscribe）
# =============================================================================
class webapp (
  String $app_name = 'puppet-lab',
  String $app_env  = 'dev',
) {
  package { 'nginx':
    ensure => installed,
  }

  file { '/etc/nginx/conf.d/app.conf':
    ensure  => file,
    content => epp('webapp/app.conf.epp', {
      'app_name' => $app_name,
      'app_env'  => $app_env,
    }),
    mode    => '0644',
    require => Package['nginx'],
  }

  # 容器内没有 systemd：reload 失败就冷启动（|| nginx）
  exec { 'reload-or-start-nginx':
    command     => '/bin/bash -c \'nginx -t && (nginx -s reload 2>/dev/null || nginx)\'',
    refreshonly => true,                      # 只在订阅对象变化时执行（≈ handler/onchanges）
    subscribe   => File['/etc/nginx/conf.d/app.conf'],
    require     => Package['nginx'],
  }

  # 首次启动：nginx 装好后必须拉起一次（refreshonly 的 exec 不会主动跑）
  exec { 'first-start-nginx':
    command => '/usr/sbin/nginx',
    unless  => '/bin/bash -c \'pgrep -f "nginx: master" >/dev/null\'',   # 幂等护栏
    require => File['/etc/nginx/conf.d/app.conf'],
  }

  File['/etc/nginx/conf.d/app.conf'] -> Exec['first-start-nginx']
}
