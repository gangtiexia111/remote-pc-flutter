#!/bin/bash
# ──────────────────────────────────────────────────────
# Remote PC Flutter — Release Build Script
# 五端构建 + Dart 代码混淆 + 符号分离
# ──────────────────────────────────────────────────────
set -euo pipefail

FLUTTER="C:/Users/Administrator/flutter/bin/flutter.bat"
PROJECT="C:/Users/Administrator/Desktop/remote-pc-flutter"
VERSION="1.0.3"
OBFUSCATE="--obfuscate --split-debug-info=${PROJECT}/build/debug-info"

echo "🔧 Remote PC v${VERSION} — Release Build with Obfuscation"
echo "========================================================="

# ── Windows ──────────────────────────────────────────
echo ""
echo "📦 [1/5] Building Windows..."
cd "${PROJECT}"
${FLUTTER} build windows --release ${OBFUSCATE}
echo "✅ Windows build complete"

# ── Android ──────────────────────────────────────────
echo ""
echo "📦 [2/5] Building Android APK..."
${FLUTTER} build apk --release ${OBFUSCATE}
echo "✅ Android APK build complete"

# ── macOS ────────────────────────────────────────────
echo ""
echo "📦 [3/5] Building macOS..."
${FLUTTER} build macos --release ${OBFUSCATE}
echo "✅ macOS build complete"

# ── iOS ──────────────────────────────────────────────
echo ""
echo "📦 [4/5] Building iOS..."
${FLUTTER} build ios --release ${OBFUSCATE} --no-codesign
echo "✅ iOS build complete"

# ── Linux ────────────────────────────────────────────
echo ""
echo "📦 [5/5] Building Linux..."
${FLUTTER} build linux --release ${OBFUSCATE}
echo "✅ Linux build complete"

echo ""
echo "========================================================="
echo "🎉 All 5 platforms built successfully!"
echo ""
echo "⚠️  debug-info 符号文件保存在: ${PROJECT}/build/debug-info/"
echo "    这些文件用于混淆后的 crash 日志还原，请妥善保管！"
echo "    ⚠️  不要将 debug-info 目录提交到 Git！"
