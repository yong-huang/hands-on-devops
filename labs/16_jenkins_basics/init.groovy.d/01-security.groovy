// =============================================================================
// 01-security.groovy — 安全与执行器初始化
// 教学：靶场内固定口令 admin/admin123（.gitignore 之外明示）；生产必须接 SSO/LDAP
// =============================================================================
import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy

def jenkins = Jenkins.get()
jenkins.setNumExecutors(2)          // 两个 executor：实验 17 的并行 stage 需要

if (jenkins.getSecurityRealm() == HudsonPrivateSecurityRealm.NONE) {
    def realm = new HudsonPrivateSecurityRealm(false)
    realm.createAccount("admin", "admin123")
    jenkins.setSecurityRealm(realm)
    jenkins.setAuthorizationStrategy(new FullControlOnceLoggedInAuthorizationStrategy())
}

jenkins.save()
println('[hands-on] init done: admin user + executors=2')
