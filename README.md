# 显示器切换 / DisplayInputSwitch

macOS 菜单栏、Windows 托盘工具。通过 DDC/CI 切换多台显示器的输入源，支持可编辑组别、全局快捷键、配置导入导出和本地日志。

## 默认组别

| 组别 | QX 视频 | QE 视频 | QX USB 目标 |
| --- | --- | --- | --- |
| Mac 1 | USB-C 90W | USB-C 90W | Mac 的 90W USB-C 上行 |
| Mac 2 | USB-C 90W | HDMI | Mac 的 90W USB-C 上行 |
| Windows | DP | DP | 独立 USB-C 数据上行，线缆另一端 USB-A 接电脑 |

默认显示器序列号：QX `J80FDH3`，QE `330BJ04`。通过序列号匹配，避免同型号屏幕或操作系统枚举顺序变化导致误切。其他设备可导出 JSON，修改 `monitors`、组内 `displays` 和 `usbSerial`，再导入。Mac 1 和 Mac 2 都使用 QX 的同一物理 USB-C 视频和 USB 上行。

## 使用

- 点击菜单栏 / 托盘中的组名，同时发送该组的显示器切换计划。设置中可添加、删除组别，修改名称、每屏输入源和 USB 归属；USB 可选 Mac、Windows、保持现状。
- 全局快捷键：macOS `Control + Option + Command + 数字`；Windows `Ctrl + Alt + Shift + 数字`。组内设置数字 1–9，0 关闭该组快捷键。保存配置后注册，注册冲突会在设置中显示。
- 保留独立的 `USB → Mac` / `USB → Windows` 操作入口，使用前需完成下述硬件支持确认。
- “检测 / 读取”只读取显示器列表和视频输入。日志区分 DDC 回读确认、请求已发送但回读不可用、输入不匹配、逐屏错误及 USB 未执行。DDC 回读不证明画面已点亮。
- 开启显示器的 DDC/CI。其他显示器控制工具可能争用通道；本程序不会自行退出它们。

### USB 控制的当前限制

**视频分组切换已实现；当前这台 U2723QX 的独立 USB 切换尚未完成硬件适配。** 实机只读查询得到 `E7=0xFFFE`、`EE` 无有效响应，不能把 E7 返回值当作当前 USB 归属，也不能据此猜测上行选择指令。

两个平台均保存每组的 USB 目标，提供独立 USB 入口及校准读取功能。只有显示器返回有效、不同的两组 USB 关联映射，才能启用对应输入下的关联写入；默认没有校准值。未支持或未校准时，切组仍切视频，并报告 **USB 未执行**，独立 USB 请求则不写入显示器。当前 QX 会拒绝校准其 `0xFFFE` 返回值，不能称作 USB 控制已经可用。

关联映射校准适用于确实开放此接口的固件：对同一视频输入，用显示器菜单分别指定 USB 到 Mac 和 Windows，再读取两个状态，保存配置。软件只修改两次状态之间变化的位，保留其他位。此路径尚未做真实 USB 写入验证。不会把 `0xFF00` 等非幂等动作码当作可重复的端口选择命令。

### 批量切换边界

切换前匹配全部目标并打开全部 DDC 句柄；任一目标缺失或重复时，本组不发送。开始发送后，硬件仍可能拒绝某一屏的请求，因此不保证物理同时完成，也不自动回滚。macOS 输入源请求使用两次相同写入，间隔 50ms；Windows 使用 DXVA2。视频先发送，USB 关联后发送，避免 USB 上行变化先断开控制通路。

切到另一主机后，DDC 通道可能消失。另一台主机需要运行本工具且能检测到显示器，才能从该端切回；程序不通过网络代理控制另一台主机。

## 构建和检查

macOS：Apple Silicon，macOS 14+，Xcode Command Line Tools。

```sh
zsh test.sh
open build/显示器切换.app
```

Windows：Windows 10/11 x64，使用 .NET 8 SDK 构建；发布为独立应用，不要求目标电脑安装 .NET。

```powershell
dotnet run --project Tests/WindowsCore/WindowsCore.csproj
dotnet publish Windows/DisplayInputSwitch.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o build/windows-x64
```

也可在 macOS 交叉构建 Windows 版本：`DOTNET_BIN=/path/to/dotnet zsh build-windows.sh`。输出 `build/windows-x64/DisplayInputSwitch.exe`。构建产物、本地 SDK、日志和 IDE 生成目录不入 Git。

已验证：Swift / .NET 配置验证与往返序列化、输入源白名单、快捷键冲突配置拒绝、USB 未校准拒绝和位掩码保留、DDC 报文及响应校验、EDID 序列号解析，macOS 应用编译和 Windows x64 发布。

未验证：Windows GUI / DXVA2 实机；新版完整双屏切换及 USB 写入。旧版单屏 DP / USB-C 切换曾实测；原先切换后黑屏且 OSD 不显示的问题，在显示器恢复出厂设置后已由使用者确认消失。

## 配置与日志

JSON schema version 1，两端可互相导入导出；示例见 [Shared/default.json](Shared/default.json)。导入先校验版本、序列号、组别、输入源、USB 值及快捷键重复；非法配置不覆盖原文件。设置编辑后点击保存。

| 文件 | macOS | Windows |
| --- | --- | --- |
| 配置 | `~/Library/Application Support/DisplayInputSwitch/config.json` | `%LOCALAPPDATA%/DisplayInputSwitch/config.json` |
| 日志 | `~/Library/Logs/DisplayInputSwitch/switch.log` | `%LOCALAPPDATA%/DisplayInputSwitch/switch.log` |

配置和日志保存在本机，不会自动上传。

macOS 命令行接口：

```sh
helper="build/显示器切换.app/Contents/Resources/input-ddc"
"$helper" list
"$helper" get J80FDH3
"$helper" usb-read J80FDH3
# 以下会切换两屏到 DP：
"$helper" batch '[{"serial":"J80FDH3","input":15},{"serial":"330BJ04","input":15}]'
```

输入源 VCP `0x60`：DP 15、HDMI 17、USB-C 27。Dell 返回值高字节是请求主机所在输入，低字节是当前选中的输入，例如 `0x1B0F` 表示从 USB-C 主机读取，当前选择 DP。

## 第三方代码

macOS 显示器枚举和通道匹配来自 MIT 项目 [m1ddc](https://github.com/waydabber/m1ddc)，固定提交 `04d949794102eb8df01ad3681afff6464a3eede2`，许可在 [vendor/m1ddc/LICENSE](vendor/m1ddc/LICENSE)。仅链接其 `ioregistry.m`。macOS 控制通道使用私有系统接口，系统升级可能影响兼容性。
