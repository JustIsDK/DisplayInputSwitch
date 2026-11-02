# Agent instructions

本项目的开发约束、硬件边界、测试分级和发布流程统一记录在 [DEVELOPMENT.md](DEVELOPMENT.md)。开始修改前先阅读它；出现冲突时，以用户当前明确要求和代码实测结果为准，并更新文档。

执行任务时遵循这些底线：

- 不加入 Dell DDPM、Dell SDK 或其二进制；Dell U2723QX / U2723QE 的 Smart HDR 使用项目自有 DDC helper 和 macOS 状态接口。
- 不把 USB 归属、音频输出或音量控制描述成已实现功能；不把外部 USB-C 切换器纳入自动控制。
- 显示器按序列号、UUID 和型号匹配，不按枚举顺序猜测；批量写入先完整预检，回读不可用时明确报告。
- 保持 macOS、Windows 的配置 schema、输入源值、组延时和迁移行为一致；新增字段必须有默认值和测试。
- 硬件测试与只读测试分开。会触发 HDR、EDID 重连或短暂黑屏的测试不能进入默认自动流程。
- 构建产物只放 `build/`；发布通过 `scripts/release.py`，默认输出到 `/Volumes/sata11-185XXXX1365/工具`，校验成功后才清理同平台旧包。
- 完成相关测试后再提交；提交前检查 `git status`，不要提交本地配置、日志、快照或安装包。
