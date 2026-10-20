using DisplayInputSwitch;
using System.Text.Json;
using System.Text;
void Check(bool v) { if (!v) throw new Exception("Core check failed"); }
string json = File.ReadAllText("Shared/default.json");
var c = Configuration.Parse(json);
Check(c.Groups.Count == 3 && c.Groups[1].Displays[1].Input == 17);
Check(Configuration.Parse(JsonSerializer.Serialize(c, Configuration.Json)).Groups[2].Displays[0].Input == 15);
void MustReject(Action action) {
    try { action(); } catch { return; }
    throw new Exception("Invalid value accepted");
}
void Rejected(Action<Configuration> change) {
    var candidate = Configuration.Parse(json); change(candidate); MustReject(candidate.Validate);
}
Rejected(x => x.Groups[0].Shortcut = 2);
Rejected(x => x.Monitors[0].Serial = x.Monitors[1].Serial);
Rejected(x => x.Groups[0].Displays[0].Input = 16);
Rejected(x => x.Version = 3);
string legacy = File.ReadAllText("Tests/Fixtures/v1-usb-config.json").Replace("Mac 1", "自定义 Mac").Replace("\"shortcut\" : 1", "\"shortcut\" : 8");
var migrated = Configuration.Parse(legacy);
Check(migrated.Version == 2 && migrated.Groups[0].Name == "自定义 Mac" && migrated.Groups[0].Shortcut == 8);
Check(migrated.Groups[1].Displays[1].Input == 17 && migrated.Monitors[0].Serial == c.Monitors[0].Serial);
Check(!JsonSerializer.Serialize(migrated, Configuration.Json).Contains("usb"));
MustReject(() => Configuration.Parse(legacy.Replace("\"version\" : 1", "\"version\" : 3")));
foreach (var (current, maximum, expected) in new[] { (0,100,0),(100,100,100),(128,255,50),(1,8,13),(65535,65535,100) }) Check(Brightness.Percent(current,maximum) == expected);
foreach (var (current, maximum) in new[] { (-1,100),(101,100),(0,0),(0,65536) }) MustReject(() => Brightness.Percent(current,maximum));
Check(Brightness.Raw(50,255) == 128 && Brightness.Raw(100,65535) == 65535 && Brightness.Raw(0,100) == 0);
MustReject(() => Brightness.Raw(101,100));
Operation.Validate([new() { Serial = "test", Brightness = 0 }]);
Operation.Validate([new() { Serial = "test", Input = 27 }]);
foreach (var ops in new List<Operation>[] {
    [], [new() { Serial = "", Brightness = 20 }], [new() { Serial = "test", Brightness = -1 }],
    [new() { Serial = "test", Brightness = 101 }], [new() { Serial = "test", Input = 16 }],
    [new() { Serial = "test" }], [new() { Serial = "test", Input = 15, Brightness = 20 }],
    [new() { Serial = "test", Input = 15 }, new() { Serial = "test", Brightness = 20 }]
}) MustReject(() => Operation.Validate(ops));
var edid = new byte[128]; edid[57] = 0xff; Encoding.ASCII.GetBytes("J80FDH3\n     ").CopyTo(edid,59);
Check(Edid.Serial(edid) == "J80FDH3"); Check(Edid.Serial(new byte[20]) == "");
Check(StartupCommand.ForExecutable(@"C:\Apps\显示器 切换\DisplayInputSwitch.exe") == "\"C:\\Apps\\显示器 切换\\DisplayInputSwitch.exe\"");
foreach (string path in new[] { "", "bad\"path", "bad\npath", "bad\0path" }) {
    try { StartupCommand.ForExecutable(path); } catch (ArgumentException) { continue; }
    throw new Exception("Invalid startup path accepted");
}
Console.WriteLine("Windows core checks passed: shared config, validation, legacy migration, brightness validation, EDID serial and startup command quoting");
Check(Dimming.Opacity(100) == 0 && Dimming.Opacity(10) == 0.9);
foreach (int value in new[] { -1, 0, 9, 101 }) MustReject(() => Dimming.Opacity(value));
