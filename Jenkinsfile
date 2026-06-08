pipeline {
  agent none

  environment {
    // 使用 Gitee 镜像加速 Flutter SDK 下载（国内网络友好）
    FLUTTER_REPO = 'https://gitee.com/mirrors/Flutter.git'
    FLUTTER_HOME = "${WORKSPACE}/flutter-sdk"
    PUB_HOSTED_URL = 'https://pub.dev'
    FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
  }

  stages {
    // ============================================
    // macOS 构建
    // ============================================
    stage('Build macOS') {
      agent { label 'macos' }
      steps {
        sh '''
          echo "========== 安装 Flutter SDK =========="
          if [ ! -d "${FLUTTER_HOME}" ]; then
            git clone "${FLUTTER_REPO}" "${FLUTTER_HOME}" -b stable --depth 1
          fi
          export PATH="${FLUTTER_HOME}/bin:${PATH}"
          flutter --version

          echo "========== 安装依赖 =========="
          cd "${WORKSPACE}"
          flutter pub get

          echo "========== 构建 macOS =========="
          flutter build macos --release

          echo "========== 打包产物 =========="
          cd build/macos/Build/Products/Release/
          zip -r "${WORKSPACE}/remote_pc_macos.zip" remote_pc.app
          echo "macOS build done, size: $(du -sh ${WORKSPACE}/remote_pc_macos.zip)"
        '''
      }
      post {
        success {
          archiveArtifacts artifacts: 'remote_pc_macos.zip', fingerprint: true
        }
      }
    }

    // ============================================
    // Linux 构建
    // ============================================
    stage('Build Linux') {
      agent { label 'linux' }
      steps {
        sh '''
          echo "========== 安装系统依赖 =========="
          sudo apt-get update -y -qq
          sudo apt-get install -y -qq ninja-build libgtk-3-dev clang cmake pkg-config liblzma-dev

          echo "========== 安装 Flutter SDK =========="
          if [ ! -d "${FLUTTER_HOME}" ]; then
            git clone "${FLUTTER_REPO}" "${FLUTTER_HOME}" -b stable --depth 1
          fi
          export PATH="${FLUTTER_HOME}/bin:${PATH}"
          flutter --version

          echo "========== 安装依赖 =========="
          cd "${WORKSPACE}"
          flutter pub get

          echo "========== 构建 Linux =========="
          flutter build linux --release

          echo "========== 打包产物 =========="
          cd build/linux/x64/release/bundle/
          zip -r "${WORKSPACE}/remote_pc_linux.zip" .
          echo "Linux build done, size: $(du -sh ${WORKSPACE}/remote_pc_linux.zip)"
        '''
      }
      post {
        success {
          archiveArtifacts artifacts: 'remote_pc_linux.zip', fingerprint: true
        }
      }
    }
  }

  post {
    success {
      echo '=== 所有平台构建成功! ==='
    }
    failure {
      echo '=== 构建失败，请检查日志 ==='
    }
  }
}
