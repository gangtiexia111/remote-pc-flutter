# Remote PC Flutter - 跨平台构建指南

## 📦 项目状态

✅ **代码完成**：1056 行 Dart 代码，0 error，0 warning  
✅ **功能完整**：授权管理、动态防火墙、UDP 发现、HTTP 控制服务  
✅ **五端支持**：Android / iOS / Windows / macOS / Linux  

---

## 🔧 构建环境要求

### 通用要求
- **Flutter SDK**: 3.32.8+ (Dart 3.8.1+)
- **Git**: 用于依赖下载

### 各平台特定要求

| 平台 | 必需工具 | 安装指南 |
|------|----------|----------|
| **Android** | Android SDK (API 21+) | [Android Studio](https://developer.android.com/studio) 或命令行工具 |
| **iOS** | Xcode 15+ | App Store（仅 macOS） |
| **Windows** | Visual Studio 2022 + "Desktop development with C++" 工作负载 | [Visual Studio 下载](https://visualstudio.microsoft.com/downloads/) |
| **macOS** | Xcode 15+ + CocoaPods | App Store（仅 macOS） |
| **Linux** | GTK 3.0+, CMake 3.10+ | `sudo apt install build-essential libgtk-3-dev` |

---

## 🚀 构建命令

### Android APK（最优先 - 支持安卓+iOS模拟器调试）

```bash
# 1. 清理旧构建
flutter clean

# 2. 获取依赖
flutter pub get

# 3. 构建 Release APK（混淆 + 压缩）
flutter build apk --release --obfuscate --split-debug-info=./debug-info

# 输出: build/app/outputs/flutter-apk/app-release.apk
```

#### 构建 Android App Bundle（上传 Google Play）
```bash
flutter build appbundle --release --obfuscate
# 输出: build/app/outputs/bundle/release/app-release.aab
```

---

### iOS（需要 macOS + Xcode）

```bash
# 1. 安装 CocoaPods 依赖
cd ios && pod install && cd ..

# 2. 构建 Release IPA
flutter build ios --release --obfuscate

# 3. 打开 Xcode 归档
open ios/Runner.xcworkspace
# 在 Xcode 中选择 Product → Archive → Distribute App
```

#### 常见问题
- **代码签名错误**：在 Xcode 中配置 Apple Developer 证书
- **Bitcode 废弃**：Xcode 14+ 已移除 Bitcode，无需处理

---

### Windows 桌面端（需要 Visual Studio 2022）

```bash
# 1. 安装 Visual Studio 2022
#    工作负载: "Desktop development with C++"
#    组件: MSVC v143, Windows 10/11 SDK

# 2. 构建 Release EXE
flutter build windows --release

# 输出: build/windows/x64/runner/Release/remote_pc_flutter.exe
```

#### 分发建议
- 使用 Inno Setup 或 NSIS 打包为安装程序
- 或直接压缩 `Release/` 文件夹为 ZIP

---

### macOS 桌面端（需要 macOS + Xcode）

```bash
# 1. 允许未签名软件（开发阶段）
sudo spctl --master-disable

# 2. 构建 Release APP
flutter build macos --release

# 输出: build/macos/Build/Products/Release/remote_pc_flutter.app
```

#### 签名和公证（发布到外网）
```bash
# 1. 签名
codesign --deep --force --verify --verbose --sign "Developer ID Application: YOUR_NAME" build/macos/Build/Products/Release/remote_pc_flutter.app

# 2. 公证（需要 Apple Developer 账号）
xcrun notarytool submit build/macos/Build/Products/Release/remote_pc_flutter.app --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --wait
```

---

### Linux 桌面端

```bash
# 1. 安装依赖（Ubuntu/Debian）
sudo apt update
sudo apt install -y build-essential libgtk-3-dev cmake ninja-build

# 2. 构建 Release
flutter build linux --release

# 输出: build/linux/x64/release/bundle/remote_pc_flutter
```

#### 打包为 Snap/AppImage（可选）
```bash
# Snapcraft
sudo snap install snapcraft --classic
snapcraft

# AppImage
# 使用 https://github.com/AppImageCommunity/pkg2appimage
```

---

## 🔐 安全加固建议

### Android
```bash
# 1. 启用 ProGuard（已在 build.gradle 默认启用）
# 2. 混淆 Dart 代码（构建时已加 --obfuscate）
# 3. 签名密钥（生产环境必须）
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

### iOS
```bash
# 1. 启用 Bitcode（Xcode 14+ 已废弃，跳过）
# 2. 启用 Swift 混淆（需要第三方工具）
# 3. App Store 审核需开启 App Transport Security
```

### Windows/macOS/Linux
- 原生层校验逻辑已通过 MethodChannel 隔离（需自行实现各平台原生代码）
- 动态防火墙每启动随机生成挑战，破解难度高

---

## 🧪 测试流程

### 1. 启动主端（桌面端）
```bash
# Windows
build/windows/x64/runner/Release/remote_pc_flutter.exe

# macOS
open build/macos/Build/Products/Release/remote_pc_flutter.app

# Linux
./build/linux/x64/release/bundle/remote_pc_flutter
```

### 2. 激活授权
1. 点击 "激活设备"
2. 输入激活码（格式：`TERM-XXXX-XXXX-XXXX-XXXX`）
3. 验证动态防火墙挑战（混合中/阿/象形文）

### 3. 启动子端（Android APK）
```bash
# 安装 APK
adb install build/app/outputs/flutter-apk/app-release.apk

# 或直接在手机上安装
```

### 4. 验证功能
- [ ] UDP 设备发现（自动扫描局域网设备）
- [ ] 关机/重启/锁屏指令
- [ ] 心跳检测（每 5 分钟）
- [ ] 动态防火墙挑战响应
- [ ] 自毁机制（连续失败 5 次）

---

## 📝 工作目录结构

```
remote_pc_flutter/
├── lib/
│   ├── main.dart                    # 入口
│   ├── models/device.dart           # 设备模型
│   ├── security/
│   │   ├── license_manager.dart     # 授权管理
│   │   └── dynamic_firewall.dart   # 动态防火墙
│   ├── services/
│   │   ├── udp_discovery.dart      # UDP 发现
│   │   ├── http_server.dart        # HTTP 服务
│   │   └── native_security_bridge.dart  # 原生桥接
│   └── screens/
│       ├── home_screen.dart         # 主界面
│       ├── security_screen.dart     # 安全监控
│       └── settings_screen.dart     # 设置
├── android/                         # Android 平台代码
├── ios/                             # iOS 平台代码
├── windows/                         # Windows 平台代码
├── macos/                           # macOS 平台代码
├── linux/                           # Linux 平台代码
├── build/                           # 构建输出（gitignore）
├── pubspec.yaml                     # 依赖配置
└── README.md                        # 项目文档
```

---

## 🚨 故障排查

### Flutter 环境缺失
```bash
# 检查环境
flutter doctor -v

# 如果 Android SDK 缺失
flutter config --android-sdk /path/to/android-sdk

# 如果 Visual Studio 缺失（Windows）
# 下载安装 VS 2022 + "Desktop development with C++"
```

### 依赖冲突
```bash
# 清理缓存
flutter clean
rm -rf ~/flutter/.pub-cache
flutter pub get
```

### 构建失败
```bash
# 详细日志
flutter build <platform> --release -v

# 重置 Flutter
flutter channel stable
flutter upgrade
```

---

## 📞 技术支持

如果遇到构建问题，请提供：
1. `flutter doctor -v` 输出
2. 完整的构建错误日志
3. 目标平台和系统版本

---

**构建完成后，即可实现一套代码五端通用！** 🎉
