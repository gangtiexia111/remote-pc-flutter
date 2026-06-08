# Remote PC Control — Flutter 跨平台版

> 一套代码，五端运行：Android / iOS / Windows / macOS / Linux

## 📊 项目状态

✅ **代码完成**：1056 行 Dart 代码，0 error，0 warning  
✅ **五端支持**：Android / iOS / Windows / macOS / Linux 平台目录已生成  
✅ **核心功能**：授权管理、动态防火墙、UDP 发现、HTTP 控制服务  
⏳ **构建中**：需要对应平台工具链（详见 [BUILD_GUIDE.md](./BUILD_GUIDE.md)）

---

## 架构总览

```
lib/
├── main.dart                    # 入口（支持 --headless 无 UI 模式）
├── models/
│   └── device.dart             # 设备模型（对应原 Device.java）
├── security/
│   ├── license_manager.dart    # AES-256-GCM 授权激活体系
│   └── dynamic_firewall.dart  # 动态多语言防火墙（防破解核心）
├── services/
│   ├── udp_discovery.dart     # UDP 广播设备发现（端口 4567）
│   ├── http_server.dart        # HTTP REST 控制服务（端口 9998）
│   └── native_security_bridge.dart  # MethodChannel 原生安全桥接
└── screens/
    ├── home_screen.dart        # 主界面（设备列表 + 操作）
    ├── security_screen.dart    # 安全监控面板
    └── settings_screen.dart    # 设置页面（激活 + 主题）
```

---

## 安全设计

### 动态多语言防火墙（防破解核心）

桌面端防破解机制（`lib/security/dynamic_firewall.dart`）：

1. **动态验证挑战**：每次启动生成不同的混合语言验证字符串
   - 中文字符池：`验证码动态防火墙安全授权`
   - 阿拉伯文池：`التحقق جدار النار الآمن الترخيص`
   - 埃及象形文字：Unicode U+13000..U+1342F
   - 数字：`3489712056`

2. **常量时间比较**：防时序攻击（`_constantTimeEqual`）

3. **动态 AES 密钥**：每次启动根据设备指纹 + 随机数派生

4. **心跳校验**：每 5 分钟重新验证，失败 5 次触发自毁

5. **原生层校验**（MethodChannel）：
   - 关键验证逻辑放在原生层（OC/Swift/Java/C++）
   - Dart 层只做调度，不做最终决策

### 授权激活体系

- 激活码格式：`TERM-XXXX-XXXX-XXXX-XXXX`（AES-256-GCM 加密）
- 设备 ID：安全存储于 Keychain（iOS）/ Keystore（Android）/ 安全存储（桌面）
- 自毁机制：先上报主端，再清除本地激活信息（修复原 Java 版 Bug）

---

## 快速开始

### 环境要求

- **Flutter SDK**: 3.32.8+ (Dart 3.8.1+)
- **各平台工具链**（详见 [BUILD_GUIDE.md](./BUILD_GUIDE.md)）：
  - Android: Android SDK (API 21+)
  - iOS: Xcode 15+（仅 macOS）
  - Windows: Visual Studio 2022 + "Desktop development with C++"
  - macOS: Xcode 15+ + CocoaPods
  - Linux: GTK 3.0+, CMake 3.10+

### 安装依赖

```bash
flutter pub get
```

### 运行（调试模式）

```bash
# Android / iOS / 桌面端
flutter run

# Headless 模式（无 UI，仅启动网络服务）
flutter run --dart-define=HEADLESS=true
```

---

## 构建发行版

### ⚡ 快速命令

```bash
# Android APK（混淆 + 压缩）
flutter build apk --release --obfuscate --split-debug-info=./debug-info

# iOS（需要 macOS + Xcode）
flutter build ios --release --obfuscate

# Windows（需要 Visual Studio 2022）
flutter build windows --release

# macOS（需要 macOS + Xcode）
flutter build macos --release

# Linux
flutter build linux --release
```

### 📚 完整构建指南

**详细的环境配置、签名、分发指南，请查看 [BUILD_GUIDE.md](./BUILD_GUIDE.md)**

包含：
- 各平台环境搭建详细步骤
- 签名和公证流程（Android/iOS/macOS）
- 故障排查指南
- 安全加固建议

---

## Headless 模式

无 UI 后台运行（用于服务端/测试）：

```bash
# 方式 1：通过环境变量
flutter run --dart-define=HEADLESS=true

# 方式 2：通过命令行参数（已内置支持）
./your-app --headless
```

Headless 模式下，应用将：
- 不显示任何 UI 窗口
- 启动 UDP 设备发现服务
- 启动 HTTP 控制服务（端口 9998）
- 后台持续运行，直到进程被终止

---

## 与原 Java 版对照

| 功能               | Java 版                          | Flutter 版                    |
|--------------------|--------------------------------|--------------------------------|
| 设备发现           | UdpDiscovery.java              | udp_discovery.dart             |
| HTTP 控制          | DesktopHttpServer.java         | http_server.dart               |
| 授权激活           | LicenseManager.java            | license_manager.dart           |
| 防破解             | 基础校验                       | dynamic_firewall.dart（动态）  |
| 支持平台           | Windows/macOS/Linux + Android | **五端统一**                  |
| 代码维护           | 三套代码                       | **一套代码**                  |
| 动态防火墙         | ❌                             | ✅（多语言混合）              |
| 常量时间比较       | ❌                             | ✅（防时序攻击）              |

---

## 依赖包

| 包名                      | 用途                           |
|---------------------------|--------------------------------|
| `cryptography`            | AES-256-GCM 加密              |
| `flutter_secure_storage`  | 安全存储设备 ID                |
| `shared_preferences`      | 本地配置存储                   |
| `device_info_plus`        | 获取设备指纹                   |
| `permission_handler`      | 权限管理                       |
| `http`                    | HTTP 客户端                    |

> **注意**：`flutter_jailbreak_detection` 因兼容性问题已移除，越狱/Root 检测改为通过 MethodChannel 原生实现

---

## 安全加固 Checklist

- [x] AES-256-GCM 激活码加密
- [x] 动态多语言验证挑战（中文+阿拉伯文+埃及象形文+数字）
- [x] 常量时间字符串比较（防时序攻击）
- [x] 心跳校验 + 自毁机制
- [x] 动态 AES 密钥（每次启动重新派生）
- [ ] MethodChannel 原生层校验（待实现各平台原生代码）
- [ ] 反调试检测（待实现）
- [ ] 应用完整性校验（待实现）
- [ ] Obfuscation 构建验证（待构建完成后测试）

---

## 测试流程

### 1. 启动主端（桌面端）

```bash
# 调试模式
flutter run

# 或运行构建好的发行版
# Windows: build/windows/x64/runner/Release/remote_pc_flutter.exe
# macOS: open build/macos/Build/Products/Release/remote_pc_flutter.app
# Linux: ./build/linux/x64/release/bundle/remote_pc_flutter
```

### 2. 激活授权

1. 点击 **"激活设备"**
2. 输入激活码（格式：`TERM-XXXX-XXXX-XXXX-XXXX`）
3. 验证动态防火墙挑战（混合中/阿/象形文）

### 3. 启动子端（Android APK 或 iOS）

```bash
# Android
flutter build apk --release
adb install build/app/outputs/flutter-apk/app-release.apk

# iOS（需要 macOS + 真机或模拟器）
flutter run --device-id <simulator_id>
```

### 4. 验证功能

- [ ] UDP 设备发现（自动扫描局域网设备）
- [ ] 关机/重启/锁屏指令
- [ ] 心跳检测（每 5 分钟）
- [ ] 动态防火墙挑战响应
- [ ] 自毁机制（连续失败 5 次）

---

## 项目文件结构

```
remote_pc_flutter/
├── lib/                          # Dart 源代码（1056 行）
│   ├── main.dart                 # 入口
│   ├── models/device.dart        # 设备模型
│   ├── security/                 # 安全模块
│   │   ├── license_manager.dart  # 授权管理
│   │   └── dynamic_firewall.dart # 动态防火墙
│   ├── services/                 # 服务模块
│   │   ├── udp_discovery.dart   # UDP 发现
│   │   ├── http_server.dart     # HTTP 服务
│   │   └── native_security_bridge.dart  # 原生桥接
│   └── screens/                  # UI 界面
│       ├── home_screen.dart      # 主界面
│       ├── security_screen.dart  # 安全监控
│       └── settings_screen.dart  # 设置
├── android/                      # Android 平台代码
├── ios/                          # iOS 平台代码
├── windows/                      # Windows 平台代码
├── macos/                        # macOS 平台代码
├── linux/                        # Linux 平台代码
├── test/                         # 测试代码
├── build/                        # 构建输出（.gitignore）
├── pubspec.yaml                  # 依赖配置
├── analysis_options.yaml         # 代码质量规则
├── README.md                     # 项目文档（本文件）
├── BUILD_GUIDE.md               # 详细构建指南
└── .gitignore                   # Git 忽略规则
```

---

## 贡献指南

欢迎提交 Issue 和 Pull Request！

### 开发规范

- 遵循 Dart 代码规范（`dart format` + `flutter analyze`）
- 提交前确保所有测试通过
- 新功能需包含单元测试

### 代码质量

```bash
# 格式化代码
dart format lib/ test/

# 静态分析
flutter analyze

# 运行测试
flutter test
```

---

## 许可证

MIT License

---

## 联系方式

如有问题或建议，欢迎提交 Issue。

---

**一套代码，五端通用！** 🎉
