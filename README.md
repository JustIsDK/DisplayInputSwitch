# 显示器切换 / DisplayInputSwitch

macOS 菜单栏、Windows 托盘工具。通过 DDC/CI 切换多台显示器的输入源，支持可编辑组别、硬件亮度调节、全局快捷键、配置导入导出和本地日志。

## 默认组别

| 组别 | QX 视频 | QE 视频 |
| --- | --- | --- |
| Mac 1 | USB-C 90W | USB-C 90W |
| Mac 2 | USB-C 90W | HDMI |
| Windows | DP | DP |

默认显示器序列号：QX `J80FDH3`，QE `330BJ04`。通过序列号匹配，避免同型号屏幕或操作系统枚举顺序变化导致误切。其他设备可导出 JSON，修改 `monitors`、组内 `displays`，再导入。

## 使用

- 点击菜单栏 / 托盘中的组名，同时发送该组的显示器切换计划。设置中可添加、删除组别，修改名称、每屏输入源。
- “设置与日志 → 通用 → 开机启动”控制登录后自动运行，开关立即生效，首次安装默认关闭。此选项仅作用于当前电脑，不随 JSON 配置导入导出。macOS 使用系统登录项 API，如需批准会提供系统设置入口；Windows 注册当前用户的启动项，可在系统“启动应用”中管理。Mac 请放在“应用程序”文件夹，Windows 请保存在固定位置；程序移动后须重新设置开机启动。
- 全局快捷键：macOS `Control + Option + Command + 数字`；Windows `Ctrl + Alt + Shift + 数字`。组内设置数字 1–9，0 关闭该组快捷键。保存配置后注册，注册冲突会在设置中显示。
- “检测 / 读取”只读取显示器列表、视频输入和当前亮度。日志区分 DDC 回读确认、请求已发送但回读不可用、输入不匹配及逐屏错误。DDC 回读不证明画面已点亮。
- 开启显示器的 DDC/CI。其他显示器控制工具可能争用通道；本程序不会自行退出它们。

### 亮度调节

“设置与日志 → 亮度”支持每屏独立调节和所有显示器联动；macOS 菜单栏面板也提供每屏滑块。拖动松手后应用，或调整后点击“应用”。启动、检测和切换输入源均不会自动覆盖亮度。

使用 DDC/CI VCP `0x10` 调整显示器硬件亮度，按显示器返回的最大值换算为 0–100%。联动将所有屏幕设置为相同比例，滑块初始显示第一台屏幕的值；相同比例不保证不同屏幕的实际光亮一致。

发送后回读确认，失败时显示错误及实际可读值，不把滑块目标值当成成功结果。无法读取有效亮度的屏幕不可调节。HDR、显示器预设模式、转接器或其他控制工具可能限制调光；软件不会自动更改 HDR。

当前 QX 固件没有提供已验证可用的 USB 控制接口，因此已移除 USB 归属、校准和独立切换功能。USB-C 视频输入保留。音频输出选择和音量控制暂未实现。

### 批量切换边界

切换前匹配全部目标并打开全部 DDC 句柄；任一目标缺失或重复时，本组不发送。开始发送后，硬件仍可能拒绝某一屏的请求，因此不保证物理同时完成，也不自动回滚。两个平台均使用两次相同写入，间隔 50ms；Windows 使用 DXVA2。亮度批量调节还会先读取全部目标的有效亮度范围，任一失败则整组不写入。

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

已验证：Swift / .NET 配置校验与往返序列化、旧配置迁移、亮度范围和比例换算、无效控制计划拒绝、DDC 报文及响应校验、EDID 序列号解析、Windows 启动命令路径引用、macOS 应用编译和 Windows x64 发布。当前两台 Dell 的 macOS DDC 亮度读取、单屏及双屏联动写入、回读和恢复原值已实测；缺失目标时整组不发送已验证。DDC 回读确认寄存器值，视觉效果仍需实际观察。

未验证：Windows GUI / DXVA2 实机、HDR 开启时的亮度控制、此次新版完整双屏输入源切换。原先切换后黑屏且 OSD 不显示的问题，在显示器恢复出厂设置后已由使用者确认消失。开机启动已验证系统注册状态，未重启或注销测试。

## 配置与日志

JSON schema version 2，两端可互相导入导出；示例见 [Shared/default.json](Shared/default.json)。导入先校验版本、序列号、组别、输入源及快捷键重复；非法配置不覆盖原文件。设置编辑后点击保存。兼容导入 version 1：保留显示器、组名、输入源和快捷键，保存或导出时移除废弃 USB 字段并升级到 version 2。亮度不写入组别配置，也不在启动时自动应用。

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
"$helper" brightness-get J80FDH3
# 以下会将两屏亮度设为 30%：
"$helper" batch '[{"serial":"J80FDH3","brightness":30},{"serial":"330BJ04","brightness":30}]'
# 以下会切换两屏到 DP：
"$helper" batch '[{"serial":"J80FDH3","input":15},{"serial":"330BJ04","input":15}]'
```

输入源 VCP `0x60`：DP 15、HDMI 17、USB-C 27。Dell 返回值高字节是请求主机所在输入，低字节是当前选中的输入，例如 `0x1B0F` 表示从 USB-C 主机读取，当前选择 DP。

## 第三方代码

macOS 显示器枚举和通道匹配来自 MIT 项目 [m1ddc](https://github.com/waydabber/m1ddc)，固定提交 `04d949794102eb8df01ad3681afff6464a3eede2`，许可在 [vendor/m1ddc/LICENSE](vendor/m1ddc/LICENSE)。仅链接其 `ioregistry.m`。macOS 控制通道使用私有系统接口，系统升级可能影响兼容性。
