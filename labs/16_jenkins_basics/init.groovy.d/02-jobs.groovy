// =============================================================================
// init.groovy.d/02-jobs.groovy — 用 Groovy 种子创建流水线任务（Pipeline as Code）
// =============================================================================
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition

def jenkins = Jenkins.get()

def pipelineScript = '''
pipeline {
    agent any
    stages {
        stage('test') {
            steps {
                sh 'echo "unit test running"; test -n "hello-jenkins"'
            }
        }
        stage('build') {
            steps {
                sh 'tar czf webapp.tar.gz /usr/share/java 2>/dev/null | true; ls -la webapp.tar.gz'
            }
        }
        stage('publish') {
            steps {
                archiveArtifacts artifacts: 'webapp.tar.gz', fingerprint: true
            }
        }
    }
    post {
        always { echo "release-lite finished" }
    }
}
'''

if (jenkins.getItem('release-lite') == null) {
    def job = jenkins.createProject(WorkflowJob, 'release-lite')
    job.definition = new CpsFlowDefinition(pipelineScript, true)
    job.save()
    println('[hands-on] job release-lite created')
}

// 失败演示任务：test 阶段必然失败（故意注入）
def failScript = '''
pipeline {
    agent any
    stages {
        stage('test') {
            steps {
                sh 'echo "injecting failure"; exit 1'
            }
        }
        stage('build') {
            steps { echo 'should never run' }
        }
    }
}
'''
if (jenkins.getItem('release-lite-fail') == null) {
    def job = jenkins.createProject(WorkflowJob, 'release-lite-fail')
    job.definition = new CpsFlowDefinition(failScript, true)
    job.save()
    println('[hands-on] job release-lite-fail created')
}
jenkins.save()
