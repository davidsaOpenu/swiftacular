pipeline {
    agent any
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
        stage('Checkout patchset') {
            steps {
                checkout([
                    $class: 'GitSCM',
                    branches: [[name: 'FETCH_HEAD']],
                    userRemoteConfigs: [[
                        url: 'https://review.gerrithub.io/davidsaOpenu/swiftacular',
                        refspec: env.GERRIT_REFSPEC
                    ]]
                ])
            }
        }
        stage('Setup SSH Keys') {
            steps {
                withCredentials([
                    sshUserPrivateKey(credentialsId: 'vagrant-swift-package-cache-01', keyFileVariable: 'KEY_CACHE'),
                    sshUserPrivateKey(credentialsId: 'vagrant-swift-storage-01',       keyFileVariable: 'KEY_STORAGE_01'),
                    sshUserPrivateKey(credentialsId: 'vagrant-swift-storage-02',       keyFileVariable: 'KEY_STORAGE_02'),
                    sshUserPrivateKey(credentialsId: 'vagrant-swift-storage-03',       keyFileVariable: 'KEY_STORAGE_03')
                ]) {
                    sh '''
                        set -e
                        install -m 600 -D "$KEY_CACHE"      .vagrant/machines/swift-package-cache-01/libvirt/private_key
                        install -m 600 -D "$KEY_STORAGE_01" .vagrant/machines/swift-storage-01/libvirt/private_key
                        install -m 600 -D "$KEY_STORAGE_02" .vagrant/machines/swift-storage-02/libvirt/private_key
                        install -m 600 -D "$KEY_STORAGE_03" .vagrant/machines/swift-storage-03/libvirt/private_key
                    '''
                }
            }
        }
        stage('Run Workload Tests') {
            steps {
                sh 'ansible-playbook -i hosts setup_workload_test.yml'
            }
        }
    }
    post {
        always {
            echo 'Workload tests completed'
        }
    }
}
