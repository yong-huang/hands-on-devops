# =============================================================================
# recipes/default.rb — Chef 配方：Ruby DSL，资源声明式、执行有顺序
#
# 与 Ansible/Salt 的对应关系：
#   package 'nginx'      ≈ pkg.installed / apt 模块
#   template 资源         ≈ template/file.managed（变更可通知其他资源）
#   execute + notifies   ≈ handler/onchanges（只在真变化时执行）
# =============================================================================
package 'nginx' do
  action :install
end

template '/etc/nginx/conf.d/app.conf' do
  source 'app.conf.erb'
  variables app_name: 'chef-lab', app_env: 'dev'
  notifies :run, 'execute[reload-or-start-nginx]'
end

# 配置语法门：模板写错这里先炸，比启动失败好排障
execute 'nginx-t' do
  command 'nginx -t'
  action :run
end

# 容器里没有 systemd：reload 失败就冷启动（|| nginx）
execute 'reload-or-start-nginx' do
  command 'nginx -t && (nginx -s reload 2>/dev/null || nginx)'
  action :nothing            # 只被通知触发
end
