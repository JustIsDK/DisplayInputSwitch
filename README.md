# 显示器切换 / DisplayInputSwitch

macOS 菜单栏、Windows 托盘工具。通过 DDC/CI 切换多台显示器的输入源，支持可编辑组别、亮度调节、全局快捷键、配置导入导出和本地日志。

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

“设置与日志 → 亮度”下提供三个二级页签，默认选择 **自动 · 检测 HDR**。支持每屏独立和所有显示器联动。拖动松手后应用，或调整后点击“应用”。

- **自动 · 检测 HDR**：逐屏读取当前 HDR 是否开启；开启时使用软件调暗，关闭时使用硬件 DDC，无法确认时使用软件调暗。混合 HDR/SDR 双屏分别选择方式，每屏显示实际路径。显示配置改变、读取和每次调节时重新检测，不会自动关闭 HDR，也不会因检测到 HDR 变化自动写入背光。macOS 使用与 MonitorControl 相同的私有 `CGSIsHDREnabled` 查询，系统升级可能影响可用性；Windows 使用活动显示路径的 Advanced Color 查询，新接口区分 SDR/WCG/HDR，旧接口遇到无法区分的 WCG 状态则视为未知。保留手动软件和硬件选项。

- **软件调暗 · HDR**：移植 MonitorControl 的 Gamma 表调暗路径，并保留其系统遮罩作为 HDR/Gamma 不可用时的回退。Gamma 路径保存并恢复原始三色通道表，调暗时切换 Gamma 活动维持窗口；HDR 状态保持不变。100% 表示撤掉本工具的调暗效果，最低 10%，避免全黑。支持一键恢复，切换到硬件页、导入配置或退出时恢复 Gamma 并撤掉遮罩。每次启动从 100% 开始，不自动恢复上次调暗值。只记住本机选择的调光方式，不写入共享组别 JSON。
- **硬件调光 · SDR**：通过 DDC/CI VCP `0x10` 调节背光，按显示器返回的最大值换算为 0–100%。发送后回读寄存器；**这两台 Dell 在 HDR 开启时出现寄存器变化、实际画面不变，已由使用者确认**。因此 HDR 下请使用软件页。工具不会自动关闭 HDR，也不在启动时写入背光。

联动将所有屏幕设为相同比例，滑块初始显示第一台屏幕的值；相同比例不代表不同屏幕的实际光亮一致。软件模式通过操作系统桌面坐标映射目标，不要求 DDC 调光可用；目标缺失或身份不唯一时整组不应用。显示器移除后撤掉其遮罩，布局变化时更新覆盖区域。

软件调暗只影响当前主机画面；不会提高显示器背光亮度。与 MonitorControl、夜间调色等软件同时运行时，Gamma 或遮罩效果会叠加，本工具不会改写其他工具设置。切换 macOS 桌面空间后会重新排列遮罩；独占全屏、受保护视频、系统安全界面可能绕过普通桌面遮罩；HDR 高光与 SDR 界面的观感比例也不保证保持一致。

当前 QX 固件没有提供已验证可用的 USB 控制接口，因此已移除 USB 归属、校准和独立切换功能。USB-C 视频输入保留。音频输出选择和音量控制暂未实现。

### 状态栏与全局快捷键

在“状态栏”（Windows 为“状态栏与快捷键”）选择分开调节或一起调节，保存后菜单栏/托盘分别显示每屏滑块或仅一个联动滑块。改变显示方式不会自动调节亮度。

每项操作均可录制组合键：切换组别、所有屏幕调亮/调暗、每屏调亮/调暗、恢复所有软件调暗。点击按键框（Windows 点击“录制”），按下包含 Control、Option/Alt 或 Command/Win 的组合键；Esc 取消，清除禁用该项，保存后注册为全局快捷键。系统占用和重复配置会显示错误。亮度步长可设置 1–20%，跟随当前逐屏调光方式；联动快捷键以第一台屏幕当前值计算，将所有屏幕设为相同比例。恢复操作只撤掉本工具的遮罩。

macOS 调节成功后，在目标屏幕下方显示类似系统亮度提示的太阳图标、屏幕名、百分比和进度条；约 1.2 秒后淡出。联动时两屏分别显示，连续操作更新原浮层，不抢焦点、不挡鼠标。调暗遮罩使用与 MonitorControl 相同的 `CGShieldingWindowLevel()` 系统层级，因此输入法候选条等普通系统叠加窗口也会一起变暗。调节期间保留现有亮度数值，完成读取后一次更新，不再反复禁用整页；连续调节会合并待处理请求，拖动时保留滑块位置。Windows 同步修复整页禁用引起的闪烁；系统样式浮层目前仅用于 macOS。

macOS “状态栏 → 使用键盘顶部亮度键”是独立的本机开关，默认关闭，立即生效，不随 JSON 导入导出。启用后需在系统设置 → 隐私与安全性 → 辅助功能中允许“显示器切换”，返回本工具设置页即可重试；权限不足或系统无法接入会显示原因，原有自定义全局快捷键仍可用。启用时，联动布局调全部配置屏幕，分开布局调鼠标所在的配置屏幕；无可用目标时保留系统行为。不接管音量、键盘背光、内置屏幕调光或 Command/Control/Option 修饰的系统亮度键组合。顶排设为标准 F1、F2 时，请配合 Fn 使用太阳图标功能。同类工具若也接管亮度键，建议只在一个工具中启用。

自定义组别组合键覆盖组内原有数字快捷键；清除后该组快捷键禁用。跨平台导入时 Command 对应 Win，Option 对应 Alt；系统保留组合键可能无法注册。录制时暂时停用本工具快捷键，结束或取消后恢复已保存的绑定。

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

已验证：Swift / .NET 配置校验与往返序列化、旧配置迁移、亮度范围和比例换算、无效控制计划拒绝、DDC 报文及响应校验、EDID 序列号解析、Windows 启动命令路径引用、快捷键冲突与旧配置迁移、亮度步长边界、HDR 路由、Win32 结构布局、macOS 应用编译和 Windows x64 发布。当前两台 Dell 的 macOS DDC 寄存器读写和回读已验证，但 HDR 下物理亮度不变。软件遮罩已用双屏白色测试窗口和屏幕像素采样验证实际变暗及 100% 恢复；单屏、联动、缺失目标整组拒绝已验证。Mac 亮度浮层已验证目标变化、窗口复用、鼠标穿透、不抢焦点与自动消失；亮度键事件解析及模拟按下/松开通过测试。连续 12 次调暗从双屏 100% 到 40%，30 次界面采样中滑块未禁用、布局保持固定。应用本身尚未获辅助功能权限，实体顶部亮度键待授权后确认。Mac 两屏当前 HDR 状态已读到开启并选择软件调暗；录制、Esc 取消和保存快捷键、Finder 前台时全局调亮/调暗/恢复、单屏快捷键、菜单栏一条/两条滑块均已验证。

未验证：Windows GUI / DXVA2 / 软件遮罩实机、HDR 视频和独占全屏、此次新版完整双屏输入源切换。原先切换后黑屏且 OSD 不显示的问题，在显示器恢复出厂设置后已由使用者确认消失。开机启动已验证系统注册状态，未重启或注销测试。

## 配置与日志

JSON schema version 3，两端可互相导入导出；示例见 [Shared/default.json](Shared/default.json)。导入先校验版本、序列号、组别、输入源及快捷键重复；非法配置不覆盖原文件。设置编辑后点击保存。兼容导入 version 1/2：保留显示器、组名、输入源和快捷键，保存或导出时移除废弃 USB 字段并升级到 version 3。新增的滑块布局、步长及自定义快捷键随 JSON 共享；旧配置默认每屏一条、步长 5%、保留原组别快捷键。亮度数值和自动/软件/硬件方式仅属于本机，亮度不在启动时自动应用。

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

MonitorControl 遮罩调暗实现基于 [MonitorControl](https://github.com/MonitorControl/MonitorControl) 的 `DisplayManager.swift`，固定提交 `7cfe64500d19cbbcbf82121a91c826f658a403bd`，MIT 许可见 [vendor/MonitorControl/LICENSE](vendor/MonitorControl/LICENSE)。macOS 使用 AppKit，Windows 移植为不激活、鼠标穿透的分层窗口。此集成仅覆盖本工具的亮度调节，不包含 MonitorControl 的音量、对比度、媒体键或整套设置界面。许可随两端安装包分发，无须额外运行 MonitorControl。

可选 macOS 视觉烟雾测试（会短暂显示白色测试块、调暗再恢复）：

```sh
xcrun swiftc Sources/Configuration.swift Sources/SoftwareDimming.swift Tests/SoftwareDimming/main.swift -o build/software-dimming-check
build/software-dimming-check
```

可选 macOS 亮度提示与功能键检查（短暂显示浮层；不调节亮度、不请求系统权限）：

```sh
xcrun swiftc -parse-as-library Sources/Configuration.swift Sources/SoftwareDimming.swift Sources/BrightnessHUD.swift Sources/BrightnessKeys.swift Tests/BrightnessFeedback/main.swift -o build/brightness-feedback-check
build/brightness-feedback-check
```
