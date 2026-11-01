# 给 dev1 发 PAT（semi-dev1）——MR 的作者必须是 dev1，root 不能审批自己开的 MR
user = User.find_by_username('dev1')
PersonalAccessToken.where(user_id: user.id, name: 'semi-dev1', revoked: false).each(&:revoke!)
t = user.personal_access_tokens.create!(
  name: 'semi-dev1',
  scopes: [:api, :write_repository, :read_repository],
  expires_at: 30.days.from_now
)
t.set_token(SecureRandom.hex(32))
t.save!
puts t.token
