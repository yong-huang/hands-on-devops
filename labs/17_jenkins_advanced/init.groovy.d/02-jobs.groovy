// =============================================================================
// 02-jobs.groovy — 注册共享库（git 仓）+ 创建两个任务
// =============================================================================
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition
import org.jenkinsci.plugins.workflow.libs.LibraryConfiguration
import org.jenkinsci.plugins.workflow.libs.SCMSourceRetriever
import jenkins.plugins.git.GitSCMSource

def jenkins = Jenkins.get()

import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl
import com.cloudbees.plugins.credentials.domains.Domain
import hudson.util.Secret

def store = SystemCredentialsProvider.getInstance().getStore()
def exists = store.getCredentials(Domain.global())
    .findAll { it.id == 'registry-pass' }
if (exists.isEmpty()) {
    store.addCredentials(Domain.global(),
        new StringCredentialsImpl(CredentialsScope.GLOBAL, 'registry-pass',
            'lab registry password', Secret.fromString('supersecret123')))
    jenkins.save()
    println('[hands-on] registry-pass created')
}


def libDesc = jenkins.getDescriptor('org.jenkinsci.plugins.workflow.libs.GlobalLibraries')
if (libDesc != null && (libDesc.libraries == null || libDesc.libraries.isEmpty())) {
    def lib = new LibraryConfiguration('devopslib',
        new SCMSourceRetriever(new GitSCMSource('file:///var/jenkins_home/shared-lib')))
    lib.implicit = true
    lib.defaultVersion = 'master'
    libDesc.libraries = [lib]
    libDesc.save()
    println('[hands-on] shared library registered')
}

def script = '''pipeline {
    agent any
    stages {
        stage('parallel') {
            parallel {
                stage('build')  { steps { sh 'sleep 4; echo build done' } }
                stage('scan')   { steps { sh 'sleep 4; echo scan done' } }
            }
        }
        stage('secret') {
            steps {
                withCredentials([string(credentialsId: 'registry-pass', variable: 'REG_PASS')]) {
                    sh 'set +x; echo "pushing with password (masked in log)"'
                }
            }
        }
        stage('shared') {
            steps { script { hello('jenkins-17') } }
        }
    }
}
'''

def failScript = '''pipeline {
    agent any
    stages {
        stage('leak') {
            steps { sh 'echo "password is supersecret123"' }
        }
    }
}
'''

[['deep-release', script], ['deep-leak-demo', failScript]].each { name, text ->
    if (jenkins.getItem(name) == null) {
        def job = jenkins.createProject(WorkflowJob, name)
        job.definition = new CpsFlowDefinition(text, true)
        job.save()
    }
}
jenkins.save()
println('[hands-on] deep jobs created')
