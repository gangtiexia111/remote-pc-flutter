# Codemagic CI/CD 配置操作指南

## 当前状态

- ✅ Gitee 仓库已推送代码（`git@gitee.com:iron-man-111/remote-pc-flutter.git`）
- ✅ GitHub 仓库存在（`https://github.com/gangtiexia111/remote-pc-flutter`）
- ⏳ GitHub 推送需要 HTTPS 认证（本地 git 未配置）
- ⏳ Codemagic 需要手动添加项目和配置 Webhook

---

## 操作步骤 1: 推送代码到 GitHub

打开终端执行：

```bash
cd C:\Users\Administrator\Desktop\remote-pc-flutter

# 如果有 GitHub Personal Access Token:
git push https://<YOUR_TOKEN>@github.com/gangtiexia111/remote-pc-flutter.git main

# 或者手动配置 SSH（推荐长期使用）:
# 1. 把 ~/.ssh/id_ed25519.pub 添加到 GitHub Settings → SSH Keys
# 2. git remote set-url origin git@github.com:gangtiexia111/remote-pc-flutter.git
# 3. git push origin main
```

## 操作步骤 2: 在 Codemagic 添加项目

1. 登录 https://codemagic.io
2. 点击 **Add application** 或 **+ New app**
3. 选择 **GitHub** 作为代码源
4. 授权 Codemagic 访问你的 GitHub 账号（gangtiexia111）
5. 选择 `remote-pc-flutter` 仓库
6. 选择 **Use codemagic.yaml** 配置模式（重要！不要选 Flutter IDE）
7. 确认项目创建

## 操作步骤 3: 触发首次构建

Codemagic 添加项目后，`codemagic.yaml` 中的触发规则会自动生效：

- **push 到 main/develop 分支** → 自动触发 iOS/macOS/Linux/Android 构建
- **PR 到 main/develop 分支** → 自动触发构建

手动触发方式：
1. 在 Codemagic 项目页面点击 **Start new build**
2. 选择分支 `main`
3. 选择工作流（建议先测试 `android-build` 或 `linux-build`，速度最快）

## 操作步骤 4: 配置 Gitee → Codemagic Webhook（可选）

如果需要 Gitee 推送也触发 Codemagic 构建：

1. 在 Codemagic 项目设置 → **Webhooks** → 复制 Webhook URL
2. 登录 https://gitee.com/iron-man-111/remote-pc-flutter/hooks
3. 点击 **添加 WebHook**
4. URL 粘贴 Codemagic Webhook URL
5. 勾选 `Push` 事件
6. 点击 **添加**

## 构建工作流说明

| 工作流 | 平台 | 实例 | 预计时间 | 安全模式 |
|--------|------|------|---------|---------|
| ios-build | iOS (无签名) | mac_mini_m2 | ~12min | ✅ |
| macos-build | macOS | mac_mini_m2 | ~10min | ✅ |
| linux-build | Linux | linux_x2 | ~6min | ✅ |
| android-build | Android APK | mac_mini_m2 | ~8min | ✅ |

所有构建默认启用 `SAFE_MODE=1`，构建完成邮件通知至 `dev@remote-pc.app`

## 预期构建结果

### iOS 构建
- 输出: `build/ios/iphoneos/Runner.app`
- 需要 Apple 开发者账号才能签名安装到真机
- 无签名构建用于验证 Swift 原生桥接编译

### macOS 构建
- 输出: `build/macos/Build/Products/Release/remote_pc.app`
- 验证 Swift 原生安全桥接（sysctl P_TRACED + codesign + IOKit）

### Android 构建
- 输出: `build/app/outputs/flutter-apk/app-release.apk`
- 验证 Kotlin 原生桥接（isDebuggerConnected + APK 签名 + 模拟器检测）

## 费用

- Codemagic 免费版: 每月 500 分钟
- 一次全平台构建约 36 分钟
- 每月可构建约 13 次

## 验证 Swift 原生桥接

macOS/iOS 构建成功即证明 Swift 原生安全桥接代码编译通过：
- `sysctl` 调用（P_TRACED 检测）
- `codesign` 验证
- `IOKit` 硬件指纹
- Keychain 清除自毁

如果构建失败，在 Codemagic 构建日志中查看具体错误，将日志截图发给我修复。
