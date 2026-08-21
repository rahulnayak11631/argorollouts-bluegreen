// Deploys bluegreen-demo to the `test` namespace ONLY (no dev step) via a
// Blue-Green Rollout, with an explicit human approval gate before promotion.
// test's Rollout has autoPromotionEnabled: false specifically so this gate
// has teeth - see k8s/overlays/test/patch-rollout.yaml.
//
// Runs entirely on the Jenkins built-in node (worker-02), which already has
// docker/kubectl/git plus kustomize, yq, argocd, kubectl-argo-rollouts in
// /usr/local/bin (installed for the GitHub Actions runner on this same box -
// not on jenkins's default PATH, hence the explicit PATH export below).
node {
    def IMAGE = 'rahulnayak11631/bluegreen-demo'
    env.PATH = "/usr/local/bin:${env.PATH}"
    env.KUBECONFIG = '/var/lib/jenkins/.kube/ci-deployer.config'

    stage('Checkout') {
        checkout([$class: 'GitSCM',
            branches: [[name: '*/main']],
            extensions: [],
            userRemoteConfigs: [[url: 'https://github.com/rahulnayak11631/argorollouts-bluegreen.git']]
        ])
    }

    stage('Build') {
        sh '''
            cd app
            mvn -f pom.xml clean package -DskipTests
        '''
    }

    stage('Docker Build') {
        sh "docker build -t ${IMAGE}:${BUILD_NUMBER} ./app"
    }

    stage('Docker Hub Push') {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-rahulnayak11631', usernameVariable: 'DOCKER_USER', passwordVariable: 'DOCKER_PASS')]) {
            sh """
                echo "\$DOCKER_PASS" | docker login -u "\$DOCKER_USER" --password-stdin
                docker push ${IMAGE}:${BUILD_NUMBER}
                docker rmi ${IMAGE}:${BUILD_NUMBER}
            """
        }
    }

    stage('Update Git Manifest (test overlay)') {
        withCredentials([string(credentialsId: 'github-argorollouts-pat', variable: 'GIT_TOKEN')]) {
            sh """
                cd k8s/overlays/test
                kustomize edit set image ${IMAGE}=${IMAGE}:${BUILD_NUMBER}
                yq -i '(.[] | select(.path == "/spec/template/spec/containers/0/env/0/value")).value = "${BUILD_NUMBER}"' patch-rollout.yaml
                cd ../../..
                git config user.name "jenkins-bot"
                git config user.email "jenkins-bot@users.noreply.github.com"
                git commit -am "deploy(test): bump image to ${BUILD_NUMBER} [Jenkins build #${BUILD_NUMBER}]" || echo "nothing to commit"
                git push https://\${GIT_TOKEN}@github.com/rahulnayak11631/argorollouts-bluegreen.git HEAD:main
            """
        }
    }

    stage('ArgoCD Sync') {
        withCredentials([string(credentialsId: 'argocd-ci-token', variable: 'ARGOCD_TOKEN')]) {
            sh """
                argocd app sync bluegreen-demo-test \
                    --server 10.110.112.200:80 --plaintext --grpc-web --grpc-web-root-path argocd \
                    --auth-token "\$ARGOCD_TOKEN" --timeout 180
            """
        }
    }

    stage('Test Ingress Endpoint') {
        sh '''
            bash ci/scripts/wait-for-phase.sh test Paused,Healthy 180
            bash ci/scripts/smoke-test.sh /test-bluegreen-preview "${BUILD_NUMBER}"
        '''
    }

    stage('Review & Promote') {
        def phase = sh(script: "kubectl get rollout bluegreen-demo -n test -o jsonpath='{.status.phase}'", returnStdout: true).trim()

        if (phase != 'Paused') {
            echo "Rollout is already at phase=${phase} (first-ever revision auto-completes with nothing to promote) - nothing to approve."
            return
        }

        echo """
        ================================================================
        Build #${BUILD_NUMBER} is deployed as PREVIEW in test and passed
        its smoke test (health + version check against
        /test-bluegreen-preview). It is NOT yet serving live traffic on
        /test-bluegreen - that only happens after promotion below.

        Inspect it yourself before deciding:
          https://ai-poc-ingress:31083/test-bluegreen-preview/version
          kubectl argo rollouts get rollout bluegreen-demo -n test
        ================================================================
        """

        def approved = true
        try {
            timeout(time: 30, unit: 'MINUTES') {
                input message: "Promote bluegreen-demo build #${BUILD_NUMBER} to ACTIVE in test?", ok: 'Promote'
            }
        } catch (err) {
            approved = false
        }

        if (approved) {
            sh 'kubectl argo rollouts promote bluegreen-demo -n test'
            sh 'bash ci/scripts/wait-for-phase.sh test Healthy 180'
            sh 'bash ci/scripts/smoke-test.sh /test-bluegreen "${BUILD_NUMBER}"'
            echo "Promoted. https://ai-poc-ingress:31083/test-bluegreen/version now serves build #${BUILD_NUMBER}."
        } else {
            sh 'kubectl argo rollouts abort bluegreen-demo -n test'
            error("Promotion rejected or timed out - rollout aborted, active version in test unchanged")
        }
    }
}
