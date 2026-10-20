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
    public int Shortcut { get; set; }
}
public sealed class Configuration {
    public int Version { get; set; }
    public List<MonitorSetting> Monitors { get; set; } = [];
    public List<SwitchGroup> Groups { get; set; } = [];
    public bool ShortcutsEnabled { get; set; }
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true };
    public static bool IsSource(int v) => v is 15 or 17 or 27;
    public static string SourceName(int v) => v switch { 15 => "DP", 17 => "HDMI", 27 => "USB-C 90W", _ => $"未知 {v}" };
    public static Configuration Parse(string json) {
        var c = JsonSerializer.Deserialize<Configuration>(json, Json) ?? throw new Exception("配置为空。");
        if (c.Version == 1) c.Version = 2; // Discard removed USB fields when saving legacy files.
        c.Validate(); return c;
    }
    public void Validate() {
        void Require(bool value, string error) { if (!value) throw new Exception(error); }
        Require(Version == 2, "配置版本不支持。");
        Require(Monitors is { Count: >= 1 and <= 4 } && Groups is { Count: >= 1 and <= 9 }, "配置列表不完整。");
        Require(Monitors!.All(m => m != null && !string.IsNullOrWhiteSpace(m.Serial) && !string.IsNullOrWhiteSpace(m.Name)), "名称或序列号为空。");
        var serials = Monitors.Select(m => m.Serial).ToHashSet();
        Require(serials.Count == Monitors.Count, "显示器序列号重复。");
        Require(Groups!.All(g => g != null && !string.IsNullOrWhiteSpace(g.Id) && !string.IsNullOrWhiteSpace(g.Name) && g.Displays is { Count: > 0 }), "组别不完整。");
        Require(Groups.Select(g => g.Id).Distinct().Count() == Groups.Count, "组别标识重复。");
        var keys = new HashSet<int>();
        foreach (var g in Groups) {
            Require(g.Shortcut is >= 0 and <= 9 && (g.Shortcut == 0 || keys.Add(g.Shortcut)), "快捷键无效或重复。");
            Require(g.Displays.All(a => a != null && serials.Contains(a.Serial) && IsSource(a.Input)) && g.Displays.Select(a => a.Serial).Distinct().Count() == g.Displays.Count, "组内显示器或输入源无效。");
        }
    }
}
public sealed class Operation {
    public string Serial { get; set; } = "";
    public int? Input { get; set; }
    public int? Brightness { get; set; }
    public static void Validate(List<Operation> ops) {
        if (ops.Count is < 1 or > 8 || ops.Any(o => o == null || string.IsNullOrWhiteSpace(o.Serial)) || ops.Select(o => o.Serial).Distinct().Count() != ops.Count)
            throw new Exception("显示器控制计划为空、重复或无效。");
        foreach (var o in ops) {
            if ((o.Input == null) == (o.Brightness == null) || (o.Input is int input && !Configuration.IsSource(input)) || (o.Brightness is int percent && percent is < 0 or > 100))
                throw new Exception("每条计划须指定一个有效输入源或 0–100 的亮度。");
        }
    }
}

public static class Brightness {
    public static int Percent(int current, int maximum) {
        if (maximum is <= 0 or > 65535 || current < 0 || current > maximum) throw new Exception("显示器未返回有效亮度，请检查 DDC/CI、连接和 HDR 设置。");
        return (int)Math.Round(current * 100.0 / maximum, MidpointRounding.AwayFromZero);
    }
    public static int Raw(int percent, int maximum) {
        if (percent is < 0 or > 100 || maximum is <= 0 or > 65535) throw new Exception("亮度范围无效。");
        return (percent * maximum + 50) / 100;
    }
}
public static class Dimming {
    public static double Opacity(int percent) {
        if (percent is < 10 or > 100) throw new ArgumentOutOfRangeException(nameof(percent), "软件亮度须为 10–100%。");
        return (100 - percent) / 100.0;
    }
}
