using System.Text.Json;

namespace DisplayInputSwitch;
public sealed class MonitorSetting {
    public string Serial { get; set; } = "";
    public string Name { get; set; } = "";
}
public sealed class Assignment {
    public string Serial { get; set; } = "";
    public int Input { get; set; }
}
public sealed class SwitchGroup {
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Name { get; set; } = "新组别";
    public List<Assignment> Displays { get; set; } = [];
    public string Usb { get; set; } = "keep";
    public int Shortcut { get; set; }
}
public sealed class UsbProfile {
    public int Input { get; set; }
    public int? Mac { get; set; }
    public int? Windows { get; set; }
    [System.Text.Json.Serialization.JsonIgnore]
    public int? Mask => Mac is >= 0 and < 0xff00 && Windows is >= 0 and < 0xff00 && Mac != Windows ? Mac ^ Windows : null;
}
public sealed class Configuration {
    public int Version { get; set; }
    public List<MonitorSetting> Monitors { get; set; } = [];
    public string UsbSerial { get; set; } = "";
    public List<SwitchGroup> Groups { get; set; } = [];
    public bool ShortcutsEnabled { get; set; }
    public List<UsbProfile> UsbProfiles { get; set; } = [];
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    public static bool IsSource(int v) => v is 15 or 17 or 27;
    public static string SourceName(int v) => v switch { 15 => "DP", 17 => "HDMI", 27 => "USB-C 90W", _ => $"未知 {v}" };
    public static string UsbName(string owner) => owner switch { "mac" => "Mac · USB-C 90W", "windows" => "Windows · USB-C 数据上行", _ => "保持现状" };
    public static Configuration Parse(string json) {
        var c = JsonSerializer.Deserialize<Configuration>(json, Json) ?? throw new Exception("配置为空。");
        c.Validate(); return c;
    }
    public void Validate() {
        void Require(bool value, string error) { if (!value) throw new Exception(error); }
        Require(Version == 1, "配置版本不支持。");
        Require(Monitors is { Count: >= 1 and <= 4 } && Groups is { Count: >= 1 and <= 9 } && UsbProfiles != null, "配置列表不完整。");
        Require(Monitors!.All(m => m != null && !string.IsNullOrWhiteSpace(m.Serial) && !string.IsNullOrWhiteSpace(m.Name)), "名称或序列号为空。");
        var serials = Monitors.Select(m => m.Serial).ToHashSet();
        Require(serials.Count == Monitors.Count && serials.Contains(UsbSerial), "显示器重复或 USB 显示器不在列表中。");
        Require(Groups!.All(g => g != null && !string.IsNullOrWhiteSpace(g.Id) && !string.IsNullOrWhiteSpace(g.Name) && g.Displays is { Count: > 0 }), "组别不完整。");
        Require(Groups.Select(g => g.Id).Distinct().Count() == Groups.Count, "组别标识重复。");
        var keys = new HashSet<int>();
        foreach (var g in Groups) {
            Require(g.Usb is "keep" or "mac" or "windows", "USB 归属无效。");
            Require(g.Shortcut is >= 0 and <= 9 && (g.Shortcut == 0 || keys.Add(g.Shortcut)), "快捷键无效或重复。");
            Require(g.Displays.All(a => a != null && serials.Contains(a.Serial) && IsSource(a.Input)) && g.Displays.Select(a => a.Serial).Distinct().Count() == g.Displays.Count, "组内显示器或输入源无效。");
        }
        Require(UsbProfiles!.All(p => p != null && IsSource(p.Input) && (p.Mac == null || p.Mac is >= 0 and < 0xff00) && (p.Windows == null || p.Windows is >= 0 and < 0xff00)) && UsbProfiles!.Select(p => p.Input).Distinct().Count() == UsbProfiles!.Count, "USB 校准数据无效。");
    }
    public Operation UsbOperation(int input, string owner) {
        var p = UsbProfiles.FirstOrDefault(p => p.Input == input);
        if (owner is not ("mac" or "windows") || p?.Mask is not int mask) throw new Exception("USB 未校准或此显示器未开放可用的 USB 关联寄存器。");
        return new Operation { Serial = UsbSerial, UsbInput = input, UsbMask = mask, UsbBits = (owner == "mac" ? p.Mac!.Value : p.Windows!.Value) & mask };
    }
}
public sealed class Operation {
    public string Serial { get; set; } = "";
    public int? Input { get; set; }
    public int? UsbMask { get; set; }
    public int? UsbBits { get; set; }
    public int? UsbInput { get; set; }
}
