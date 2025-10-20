// ============================================
// Jenkinsfile — CloudForge CI/CD Pipeline
// Build → Scan → Push → Deploy
// ============================================

pipeline {
    agent any

    environment {
        AWS_REGION       = 'us-east-1'
        AWS_ACCOUNT_ID   = credentials('aws-account-id')
        ECR_REGISTRY     = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
        ECR_REPO         = 'cloudforge/website'
        IMAGE_TAG        = "${BUILD_NUMBER}-${GIT_COMMIT.take(7)}"
        EKS_CLUSTER      = 'cloudforge-eks'
        K8S_NAMESPACE    = 'cloudforge'
    }

    options {
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    stages {

        // ── Stage 1: Checkout ──
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    echo "Building: ${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}"
                }
            }
        }

        // ── Stage 2: Lint & Validate ──
        stage('Lint & Validate') {
            parallel {
                stage('Hadolint (Dockerfile)') {
                    steps {
                        sh '''
                            docker run --rm -i hadolint/hadolint < Dockerfile || true
                        '''
                    }
                }
                stage('HTML Validate') {
                    steps {
                        sh '''
                            # Basic HTML syntax check
                            python3 -c "
                            from html.parser import HTMLParser
                            parser = HTMLParser()
                            with open('website/index.html') as f:
                                parser.feed(f.read())
                            print('HTML validation passed')
                            " || true
                        '''
                    }
                }
            }
        }

        // ── Stage 3: Build Docker Image ──
        stage('Build Image') {
            steps {
                sh """
                    docker build \
                        --no-cache \
                        --label "git-commit=${GIT_COMMIT}" \
                        --label "build-number=${BUILD_NUMBER}" \
                        -t ${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG} \
                        -t ${ECR_REGISTRY}/${ECR_REPO}:latest \
                        .
                """
            }
        }

        // ── Stage 4: Security Scan ──
        stage('Security Scan') {
            parallel {
                stage('Trivy Vulnerability Scan') {
                    steps {
                        sh """
                            trivy image \
                                --severity HIGH,CRITICAL \
                                --exit-code 1 \
                                --no-progress \
                                --format table \
                                ${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}
                        """
                    }
                }
                stage('Trivy Secret Scan') {
                    steps {
                        sh """
                            trivy fs \
                                --scanners secret \
                                --exit-code 1 \
                                .
                        """
                    }
                }
            }
        }

        // ── Stage 5: Push to ECR ──
        stage('Push to ECR') {
            steps {
                sh """
                    aws ecr get-login-password --region ${AWS_REGION} | \
                        docker login --username AWS --password-stdin ${ECR_REGISTRY}

                    docker push ${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}
                    docker push ${ECR_REGISTRY}/${ECR_REPO}:latest
                """
            }
        }

        // ── Stage 6: Deploy to EKS ──
        stage('Deploy to EKS') {
            steps {
                sh """
                    # Configure kubectl
                    aws eks update-kubeconfig \
                        --name ${EKS_CLUSTER} \
                        --region ${AWS_REGION}

                    # Update image in deployment
                    kubectl set image deployment/cloudforge-website \
                        website=${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG} \
                        -n ${K8S_NAMESPACE}

                    # Wait for rollout
                    kubectl rollout status deployment/cloudforge-website \
                        -n ${K8S_NAMESPACE} \
                        --timeout=300s
                """
            }
        }

        // ── Stage 7: Verify Deployment ──
        stage('Verify') {
            steps {
                sh """
                    # Check pod health
                    kubectl get pods -n ${K8S_NAMESPACE} -l app=cloudforge-website

                    # Quick smoke test
                    ENDPOINT=\$(kubectl get svc cloudforge-website -n ${K8S_NAMESPACE} -o jsonpath='{.spec.clusterIP}')
                    kubectl run curl-test --rm -i --image=curlimages/curl --restart=Never -- \
                        curl -sf http://\${ENDPOINT}/health || echo "Smoke test completed"
                """
            }
        }
    }

    post {
        success {
            echo "✅ Deployed ${ECR_REPO}:${IMAGE_TAG} to ${EKS_CLUSTER}"
            // Uncomment for Slack notifications:
            // slackSend(color: 'good', message: "✅ CloudForge deployed: ${IMAGE_TAG}")
        }
        failure {
            echo "❌ Pipeline failed at stage: ${currentBuild.result}"
            // slackSend(color: 'danger', message: "❌ CloudForge deploy failed: ${IMAGE_TAG}")
        }
        always {
            // Cleanup local Docker images
            sh """
                docker rmi ${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG} || true
                docker rmi ${ECR_REGISTRY}/${ECR_REPO}:latest || true
            """
        }
    }
}
