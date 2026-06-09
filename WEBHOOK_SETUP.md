# Gitee → Codemagic Webhook 配置指南

## 概述

通过配置 Gitee Webhook，实现代码推送后自动触发 Codemagic 云端构建。

## 前置条件

- Gitee 仓库已创建且代码已推送
- Codemagic 账号已注册
- `codemagic.yaml` 已提交到仓库根目录

## 配置步骤

### 1. 获取 Codemagic Webhook URL

1. 登录 [Codemagic](https://codemagic.io/)
2. 进入项目设置 → **Webhooks**
3. 复制 Webhook URL，格式为：
   ```
   https://api.codemagic.io/builds?apiKey=YOUR_API_KEY
   ```

### 2. 在 Gitee 添加 Webhook

1. 进入 Gitee 仓库 → **管理** → **WebHooks**
2. 点击 **添加 WebHook**
3. 配置：
   - **URL**: 粘贴 Codemagic 的 Webhook URL
   - **密码**: 留空或设置（需在 Codemagic 侧同步配置）
   - **勾选事件**: `Push`
   - **活跃**: ✅
4. 点击 **添加**

### 3. 验证 Webhook

1. 在 Gitee 仓库做一次小改动并推送
2. 在 Codemagic 控制台查看是否触发了新构建
3. 在 Gitee WebHook 管理页面查看最近的推送记录和响应状态

## codemagic.yaml 触发配置说明

当前配置已包含 Webhook 触发规则：

```yaml
triggering:
  events:
    - push
    - pull_request
  branch_patterns:
    - pattern: 'main'
      include: true
    - pattern: 'develop'
      include: true
  cancel_previous_builds: true
```

- **push 到 main/develop 分支**: 自动触发构建
- **PR 到 main/develop 分支**: 自动触发构建
- **cancel_previous_builds**: 新构建自动取消同分支的旧构建

## SAFE_MODE 环境变量

所有构建工作流已配置 `SAFE_MODE=1` 环境变量：

```yaml
environment:
  vars:
    SAFE_MODE: "1"
```

这确保云端构建的应用默认启用安全模式。

## GitHub Actions (Linux) Webhook 配置

Linux 构建使用 GitHub Actions，已通过 `.github/workflows/build-linux.yml` 配置。

如需配置 Gitee → GitHub 同步触发：

1. 在 Gitee 仓库的 WebHook 中额外添加 GitHub Actions 触发 URL
2. 或使用 Gitee 的 **仓库镜像** 功能自动同步到 GitHub
3. GitHub 侧的 `on: push` 会自动触发 Linux 构建

## 故障排查

| 问题 | 解决方案 |
|------|---------|
| Webhook 未触发 | 检查 URL 是否正确，事件类型是否勾选 Push |
| 构建失败 | 检查 codemagic.yaml 语法，确保 flutter 版本兼容 |
| 邮件未收到 | 更新 codemagic.yaml 中的 recipients 邮箱 |
| SAFE_MODE 未生效 | 确认环境变量配置在 `environment.vars` 中 |
