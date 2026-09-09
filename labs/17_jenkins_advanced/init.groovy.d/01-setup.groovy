// =============================================================================
// 01-setup.groovy — 管理员 + API Token + 4 executors（并行前提）
// =============================================================================
import jenkins.model.Jenkins
import hudson.security.HudsonPrivateSecurityRealm
import hudson.security.FullControlOnceLoggedInAuthorizationStrategy

def jenkins = Jenkins.get()
jenkins.setNumExecutors(4)

if (!(jenkins.getSecurityRealm() instanceof HudsonPrivateSecurityRealm)) {
    def realm = new HudsonPrivateSecurityRealm(false)
    realm.createAccount("admin", "admin123")
    jenkins.setSecurityRealm(realm)
    jenkins.setAuthorizationStrategy(new FullControlOnceLoggedInAuthorizationStrategy())
}

def user = hudson.model.User.getById('admin', true)
def tokenProp = user.getProperty(jenkins.security.ApiTokenProperty)
if (tokenProp == null) {
    tokenProp = new jenkins.security.ApiTokenProperty()
    user.addProperty(tokenProp)
}
if (tokenProp.tokenList.size() == 0) {
    def result = tokenProp.generateNewToken('lab-token')
    new File('/var/jenkins_home/lab-token.txt').text = result.plainValue
    user.save()
    println('[hands-on] api token generated')
}

jenkins.save()
println('[hands-on] setup done: admin + token + executors=4')
