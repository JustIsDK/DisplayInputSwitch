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
Rejected(x => x.Version = 4);
string legacy = File.ReadAllText("Tests/Fixtures/v1-usb-config.json").Replace("Mac 1", "自定义 Mac").Replace("\"shortcut\" : 1", "\"shortcut\" : 8");
var migrated = Configuration.Parse(legacy);
Check(migrated.Version == 3 && migrated.Groups[0].Name == "自定义 Mac" && migrated.Groups[0].Shortcut == 8);
Check(migrated.Groups[1].Displays[1].Input == 17 && migrated.Monitors[0].Serial == c.Monitors[0].Serial);
Check(!JsonSerializer.Serialize(migrated, Configuration.Json).Contains("usb"));
MustReject(() => Configuration.Parse(legacy.Replace("\"version\" : 1", "\"version\" : 4")));
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

var v2 = Configuration.Parse(File.ReadAllText("Tests/Fixtures/v2-config.json"));
Check(v2.Version == 3 && !v2.MenuBrightnessLinked && v2.BrightnessStep == 5 && v2.Hotkeys.Count == 0);
Check(v2.EffectiveHotkeys(false).Select(b => b.Key).SequenceEqual(new[] { "1","2","3" }));
var custom = Configuration.Parse(json); custom.MenuBrightnessLinked = true; custom.BrightnessStep = 7;
custom.Hotkeys = [new() { Action = "brightness:down:all",Key = "DOWN",Modifiers = 11 },new() { Action = "group:mac1" }];
custom.Validate(); var copy = Configuration.Parse(JsonSerializer.Serialize(custom,Configuration.Json));
Check(copy.MenuBrightnessLinked && copy.BrightnessStep == 7 && !copy.EffectiveHotkeys(false).Any(b => b.Action == "group:mac1"));
Rejected(x => x.BrightnessStep = 0); Rejected(x => x.BrightnessStep = 21);
foreach (var b in new[] {
 new KeyBinding { Action = "missing",Key = "A",Modifiers = 1 },
 new KeyBinding { Action = "brightness:down:all",Key = "DOWN",Modifiers = 4 },
 new KeyBinding { Action = "brightness:down:all",Key = "INVALID",Modifiers = 1 },
 new KeyBinding { Action = "brightness:down:all",Key = "1",Modifiers = 7 },
 new KeyBinding { Action = "brightness:down:all",Key = "1",Modifiers = 11 }
}) Rejected(x => x.Hotkeys = [b]);
Rejected(x => x.Hotkeys = [new() { Action = "brightness:down:all",Key = "A",Modifiers = 1 },new() { Action = "brightness:up:all",Key = "A",Modifiers = 1 }]);
Check(Brightness.Adjusted(98,5,true) == 100 && Brightness.Adjusted(12,-5,true) == 10 && Brightness.Adjusted(2,-5,false) == 0);
Check(Brightness.UsesSoftware("auto",true) && !Brightness.UsesSoftware("auto",false) && Brightness.UsesSoftware("auto",null));
Check(Brightness.UsesSoftware("software",false) && !Brightness.UsesSoftware("hardware",true));
Check(KeyBinding.Keys.All(HotkeyCodes.Codes.ContainsKey) && HotkeyCodes.Modifiers(11) == 11 && HotkeyCodes.Modifiers(7) == 7 && HotkeyCodes.Modifiers(1) == 2 && HotkeyCodes.Modifiers(2) == 1);
Check(Hdr.ValidLayout() && Hdr.ActiveHdr(2) == true && Hdr.ActiveHdr(1) == false && Hdr.ActiveHdr(0) == false && Hdr.ActiveHdr(3) == null);
Console.WriteLine("Status layout, hotkey migration/conflicts, HDR routing and Win32 structure checks passed");
