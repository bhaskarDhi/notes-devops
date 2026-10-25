pipeline {
  agent any

  options {
    timestamps()
    ansiColor('xterm')
    disableConcurrentBuilds()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 20, unit: 'MINUTES')
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
  }

  post {
    always {
      sh 'docker compose -p "$CI_PROJECT" -f compose.ci.yml down -v --rmi local --remove-orphans || true'
      cleanWs()
    }
  }
}
