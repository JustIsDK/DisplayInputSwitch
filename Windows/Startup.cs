using Microsoft.Win32;
using System.Runtime.Versioning;

namespace DisplayInputSwitch;
public static class StartupCommand {
    public static string ForExecutable(string path) {
        if (string.IsNullOrWhiteSpace(path) || path.IndexOfAny(['"', '\0', '\r', '\n']) >= 0)
            throw new ArgumentException("启动程序路径无效。");
        return "\"" + path + "\"";
    }
}

[SupportedOSPlatform("windows")]
internal static class Startup {
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ValueName = "DisplayInputSwitch";
    static string Command => StartupCommand.ForExecutable(Environment.ProcessPath ?? throw new Exception("无法获取应用路径。"));
    public static bool IsRegistered() {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return string.Equals(key?.GetValue(ValueName) as string, Command, StringComparison.OrdinalIgnoreCase);
    }
    public static void SetEnabled(bool enabled) {
        if (enabled) {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, true) ?? throw new Exception("无法打开当前用户的启动项。");
            key.SetValue(ValueName, Command, RegistryValueKind.String);
        } else {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, true);
            key?.DeleteValue(ValueName, false);
        }
    }
}
