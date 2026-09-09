# site.pp — 节点入口：给默认节点应用 webapp class（参数即"传给节点的数据"）
node default {
  class { 'webapp':
    app_name => 'puppet-lab',
    app_env  => 'dev',
  }
}
