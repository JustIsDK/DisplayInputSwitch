# MonitorControl attribution

Upstream: https://github.com/MonitorControl/MonitorControl
Commit: 7cfe64500d19cbbcbf82121a91c826f658a403bd
License: MIT (see LICENSE)

Sources/SoftwareDimming.swift adapts the software brightness paths from
MonitorControl/Support/DisplayManager.swift and Model/Display.swift: the saved
Gamma transfer tables, Gamma activity enforcer, and the black click-through
window shade fallback. The implementation is scoped to configured displays,
uses UUID matching and limits dimming to 10–100%.

Windows/SoftwareDimming.cs ports the same shade approach to WinForms layered windows.
The upstream application, dependencies and unrelated controls are not bundled.
