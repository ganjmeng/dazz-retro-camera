# GitHub Actions CI/CD 流水线配置指南

本项目已配置完整的 GitHub Actions 自动化工作流，涵盖代码测试、Android/iOS 自动打包以及发布流程。

## 1. 工作流概览

| 工作流文件 | 触发条件 | 核心任务 |
|------------|----------|----------|
| `flutter_ci.yml` | Push/PR 到 `main` 分支 | 运行 Flutter 静态分析、单元测试、组件测试；执行 Android/iOS Debug 编译检查。 |
| `android_release.yml` | Push `v*.*.*` 标签 | 构建 Android AAB 和 APK（Release 模式），并作为 Artifacts 上传。支持自动签名。 |
| `ios_release.yml` | Push `v*.*.*` 标签 | 构建 iOS IPA（Release 模式），并作为 Artifacts 上传。支持自动签名。 |
| `github_release.yml` | Push `v*.*.*` 标签 | 自动在 GitHub Releases 中创建 Draft Release，生成更新日志。 |

## 2. GitHub Secrets 配置指南

为了使 Release 工作流能够成功签名并打包，您需要在 GitHub 仓库的 **Settings > Secrets and variables > Actions** 中配置以下环境变量。

### 2.1 Android 签名配置

| Secret 名称 | 说明 | 获取方式 |
|-------------|------|----------|
| `ANDROID_KEYSTORE_BASE64` | Keystore 文件的 Base64 编码 | 运行 `base64 -i my-release-key.jks` 获取 |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore 密码 | 您在生成 Keystore 时设置的密码 |
| `ANDROID_KEY_ALIAS` | 密钥别名 | 您在生成 Keystore 时设置的别名 |
| `ANDROID_KEY_PASSWORD` | 密钥密码 | 您在生成 Keystore 时设置的密钥密码 |

> **注意**：如果未配置上述 Secrets，Android 工作流将跳过签名步骤，直接构建未签名的 APK/AAB。

### 2.2 iOS 签名配置

| Secret 名称 | 说明 | 获取方式 |
|-------------|------|----------|
| `IOS_BUILD_CERTIFICATE_BASE64` | P12 证书的 Base64 编码 | 从 Keychain 导出发布证书 (P12)，运行 `base64 -i cert.p12` |
| `IOS_P12_PASSWORD` | P12 证书密码 | 导出 P12 时设置的密码 |
| `IOS_BUILD_PROVISION_PROFILE_BASE64` | 描述文件的 Base64 编码 | 下载 `.mobileprovision` 文件，运行 `base64 -i profile.mobileprovision` |
| `IOS_KEYCHAIN_PASSWORD` | 临时 Keychain 密码 | 任意强密码字符串（用于 CI 运行时的临时钥匙串） |

> **注意**：如果未配置上述 Secrets，iOS 工作流将跳过签名步骤，执行 `--no-codesign` 构建，这仅可用于测试，无法安装到真机。

## 3. 如何触发自动发布

当您准备好发布新版本时，只需在本地打一个版本标签并推送到 GitHub：

```bash
# 1. 提交所有更改
git commit -m "chore: release version 1.0.0"

# 2. 创建版本标签 (必须以 v 开头)
git tag v1.0.0

# 3. 推送标签到远程仓库
git push origin v1.0.0
```

推送标签后，GitHub Actions 将自动并行触发 `android_release`、`ios_release` 和 `github_release` 工作流。您可以在仓库的 **Actions** 标签页查看进度。完成后，打包产物将出现在对应的 Workflow 运行详情页的 Artifacts 区域，同时在 **Releases** 页面会生成一个草稿版本。
