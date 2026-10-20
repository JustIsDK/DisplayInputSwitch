using DisplayInputSwitch;
using System.Text.Json;
using System.Text;
void Check(bool v) { if (!v) throw new Exception("Core check failed"); }
string json = File.ReadAllText("Shared/default.json");
var c = Configuration.Parse(json);
Check(c.Groups.Count == 3 && c.Groups[1].Displays[1].Input == 17);
Check(Configuration.Parse(JsonSerializer.Serialize(c, Configuration.Json)).Groups[2].Usb == "windows");
void Rejected(Action<Configuration> change) {
    var candidate = Configuration.Parse(json); change(candidate);
    try { candidate.Validate(); } catch { return; }
    throw new Exception("Invalid configuration accepted");
}
Rejected(x => x.Groups[0].Shortcut = 2);
Rejected(x => x.Monitors[0].Serial = x.Monitors[1].Serial);
Rejected(x => x.Groups[0].Displays[0].Input = 16);
Rejected(x => x.UsbProfiles[0].Mac = 0xfffe);
try { c.UsbOperation(27,"mac"); throw new InvalidOperationException("Uncalibrated USB accepted"); } catch (InvalidOperationException) { throw; } catch { }
c.UsbProfiles = [new UsbProfile { Input = 27, Mac = 0x1240, Windows = 0x1280 }];
var op = c.UsbOperation(27,"mac"); Check(op.UsbMask == 0xc0 && op.UsbBits == 0x40);
Check(((0x2280 & ~op.UsbMask!.Value) | op.UsbBits!.Value) == 0x2240);
var edid = new byte[128]; edid[57] = 0xff; Encoding.ASCII.GetBytes("J80FDH3\n     ").CopyTo(edid,59);
Check(Edid.Serial(edid) == "J80FDH3"); Check(Edid.Serial(new byte[20]) == "");
Console.WriteLine("Windows core checks passed: shared config, validation, USB masking and EDID serial");
