pipeline {
  agent any

  options {
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 30, unit: 'MINUTES')
  }

  environment {
    CI_PROJECT = "ci-${env.BRANCH_NAME.toLowerCase().replaceAll('[^a-z0-9]', '-')}-${env.BUILD_NUMBER}"
  }

  stages {
    stage('Lint & Test') {
      steps {
        sh 'docker compose -p "$CI_PROJECT" -f compose.ci.yml run --rm --build tests'
      }
    }

    stage('Build image') {
      when { branch 'main' }
      steps {
        script {
          env.IMAGE_TAG = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
          env.IMAGE = "${env.ECR_REPOSITORY_URL}:${env.IMAGE_TAG}"
        }
        sh 'docker build --pull --target production --build-arg GIT_SHA="$IMAGE_TAG" -t "$IMAGE" app'
      }
    }

    stage('Security scan') {
      when { branch 'main' }
      steps {
        sh 'trivy image --no-progress --scanners vuln --severity HIGH,CRITICAL --exit-code 0 "$IMAGE"'
        sh 'trivy image --no-progress --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 "$IMAGE"'
      }
    }

    stage('Push to ECR') {
      when { branch 'main' }
      steps {
        sh '''
          REPO_NAME="${ECR_REPOSITORY_URL#*/}"
          if aws ecr describe-images --repository-name "$REPO_NAME" --image-ids imageTag="$IMAGE_TAG" >/dev/null 2>&1; then
            echo "Image $IMAGE_TAG is already in ECR - not pushing again"
          else
            docker push "$IMAGE"
          fi
        '''
      }
    }

    stage('Deploy') {
      when { branch 'main' }
      steps {
        dir('infra/ansible') {
          sh '"$ANSIBLE_PLAYBOOK" playbooks/deploy.yml -e image_tag="$IMAGE_TAG" -e use_bastion=false'
        }
        sh 'aws ssm put-parameter --name "$SSM_PREFIX/image_tag" --type String --value "$IMAGE_TAG" --overwrite'
      }
    }
  }

  post {
    success {
      script {
        if (env.BRANCH_NAME == 'main') {
          echo "Deployed ${env.IMAGE_TAG}"
        }
      }
    }
    always {
      sh 'docker compose -p "$CI_PROJECT" -f compose.ci.yml down -v --rmi local --remove-orphans || true'
      sh 'if [ -n "$IMAGE" ]; then docker image rm "$IMAGE" || true; fi'
      cleanWs()
    }
  }
}
