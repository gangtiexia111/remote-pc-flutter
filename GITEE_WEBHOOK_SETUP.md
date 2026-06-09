# Gitee Webhook 配置指南

## 步骤 1: 创建 Gitee 仓库

1. 登录 https://gitee.com （账号: iron-man-111 / 钢铁侠111）
2. 点击右上角 **+** → **新建仓库**
3. 填写：
   - 仓库名称: `remote-pc-flutter`
   - 路径: `remote-pc-flutter`
   - 可见性: 公开
   - 初始化: ❌ 不勾选（已有代码）
4. 点击 **创建**

## 步骤 2: 添加 Gitee Remote 并推送

```bash
cd C:\Users\Administrator\Desktop\remote-pc-flutter

# 添加 Gitee 作为第二个 remote
git remote add gitee git@gitee.com:iron-man-111/remote-pc-flutter.git

# 推送到 Gitee
git push gitee main
```

## 步骤 3: 配置 Codemagic Webhook

### 3.1 在 Codemagic 添加项目

1. 登录 https://codemagic.io
2. 点击 **Add application**
3. 选择 Gitee 仓库 `iron-man-111/remote-pc-flutter`
4. 选择 **Use codemagic.yaml** 配置模式

### 3.2 获取 Webhook URL

1. 在 Codemagic 项目设置中 → **Webhooks**
2. 复制 Webhook URL，格式：`https://api.codemagic.io/builds?apiKey=YOUR_API_KEY`

### 3.3 在 Gitee 添加 Webhook

1. 进入 Gitee 仓库 → **管理** → **WebHooks**
2. 点击 **添加 WebHook**
3. 配置：
   - **URL**: 粘贴 Codemagic Webhook URL
   - **密码**: 留空或设置（需在 Codemagic 侧同步）
   - **勾选事件**: `Push`
   - **活跃**: ✅
4. 点击 **添加**

## 步骤 4: 验证 Webhook

1. 做一次小改动并推送到 Gitee:
   ```bash
   git commit --allow-empty -m "test: webhook trigger"
   git push gitee main
   ```
2. 在 Codemagic 控制台查看是否触发了新构建
3. 在 Gitee WebHook 管理页面查看推送记录和响应状态

## 当前构建工作流

| 工作流 | 平台 | 触发条件 | 实例类型 |
|--------|------|---------|---------|
| ios-build | iOS | push/PR → main/develop | mac_mini_m2 |
| macos-build | macOS | push/PR → main/develop | mac_mini_m2 |
| linux-build | Linux | push/PR → main/develop | linux_x2 |
| android-build | Android | push → main | mac_mini_m2 |

所有构建均启用 SAFE_MODE=1 环境变量。

## 注意事项

- Codemagic 免费版每月 500 分钟构建时间
- macOS 构建消耗约 10-15 分钟/次
- Linux 构建消耗约 5-8 分钟/次
- 建议在 develop 分支测试，main 分支正式构建
- 构建完成后邮件通知至 dev@remote-pc.app
