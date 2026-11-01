# 一次性 rails 脚本：给 root 发名为 semi-org-guard 的 PAT（旧的同名 token 先吊销）
# org_guard.sh 用 docker cp 投进容器后以 gitlab-rails runner 执行，stdout 末行即 token
user = User.find_by_username('root')
PersonalAccessToken.where(user_id: user.id, name: 'semi-org-guard', revoked: false).each(&:revoke!)
t = user.personal_access_tokens.create!(
  name: 'semi-org-guard',
  scopes: [:api, :write_repository, :read_repository],
  expires_at: 30.days.from_now
)
t.set_token(SecureRandom.hex(32))
t.save!
puts t.token
