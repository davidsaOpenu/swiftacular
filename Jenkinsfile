pipeline {
    agent { label 'host' }
    stages {
        stage('Check ownership') {
            steps {
                script {
                    if (env.GERRIT_PATCHSET_UPLOADER_USERNAME &&
                        env.GERRIT_PATCHSET_UPLOADER_USERNAME != env.GERRIT_OWNER_USERNAME) {
                        currentBuild.result = 'NOT_BUILT'
                        error("Skipping: change belongs to ${env.GERRIT_PATCHSET_UPLOADER_USERNAME}, not ${env.GERRIT_OWNER_USERNAME}")
                    }
                }
            }
        }
        stage('Cleanup') {
            steps {
                sh './cleanup.sh'
            }
        }
        stage('Provision VMs') {
            steps {
                sh './2_provision_VMs.sh'
            }
        }
        stage('Deploy and Test') {
            steps {
                sh './3_deploy_swift_with_monitoring.sh'
            }
        }
    }
    post {
        always {
            sh './cleanup.sh'
        }
    }
}
