# 参与开发

欢迎提交修复和功能建议。请先阅读 [DEVELOPMENT.md](DEVELOPMENT.md)，那里记录了本项目的硬件假设、平台边界、配置兼容性、测试和发布规则。

一个合适的改动应包含：

- 清楚说明用户可观察到的行为变化，以及它适用的平台和设备。
- 对配置、DDC 报文、HDR、颜色描述文件或批量切换行为的变化，提供对应的自动检查；需要真实显示器时，说明前置状态、系统版本和恢复结果。
- 同步更新 README、版本说明或开发约定，尤其是“已验证 / 未验证”和功能限制。
- 不提交 `build/`、安装包、日志、本地配置、凭据或 Dell 闭源组件。

建议的本地流程：

```sh
zsh test.sh
dotnet run --project Tests/WindowsCore/WindowsCore.csproj
git diff --check
git status --short
```

提交信息用简短的英文动词开头，例如 `Fix ...`、`Add ...`、`Document ...`。一个提交尽量只表达一个行为变化，便于回溯和发布。
