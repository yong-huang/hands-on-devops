# =============================================================================
# 合规即代码：每条 control = 一条"验收标准"，describe/it 是可执行的需求
# =============================================================================
control 'webapp-01 nginx installed' do
  impact 1.0
  title 'nginx 已安装'
  describe package('nginx') do
    it { should be_installed }
  end
end

control 'webapp-02 config rendered' do
  impact 0.9
  title '站点配置已渲染且内容正确'
  describe file('/etc/nginx/conf.d/app.conf') do
    it { should exist }
    its('content') { should match /app=chef-lab env=dev/ }
  end
end

control 'webapp-03 port listening' do
  impact 0.9
  title 'nginx 监听 8080'
  describe port(8080) do
    it { should be_listening }
  end
end

control 'webapp-04 healthz ok' do
  impact 0.8
  title '健康端点返回 200 且内容正确'
  describe http('http://127.0.0.1:8080/healthz') do
    its('status') { should cmp 200 }
    its('body') { should match /app=chef-lab/ }
  end
end

control 'webapp-05 server tokens off' do
  impact 0.6
  title '安全基线：隐藏 nginx 版本号（server_tokens off）'
  describe file('/etc/nginx/conf.d/app.conf') do
    its('content') { should match /server_tokens off;/ }
  end
end
