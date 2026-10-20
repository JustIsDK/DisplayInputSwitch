# MonitorControl attribution

Upstream: https://github.com/MonitorControl/MonitorControl
Commit: 7cfe64500d19cbbcbf82121a91c826f658a403bd
License: MIT (see LICENSE)

Sources/SoftwareDimming.swift adapts the black, click-through window shade creation,
alpha adjustment, screen bounds updates and removal from
MonitorControl/Support/DisplayManager.swift (createShadeOnDisplay, setShadeAlpha,
updateShade, destroyShade). The implementation is scoped to configured displays,
uses UUID matching and limits dimming to 10–100%. No gamma tables are changed.

Windows/SoftwareDimming.cs ports the same shade approach to WinForms layered windows.
The upstream application, dependencies and unrelated controls are not bundled.
