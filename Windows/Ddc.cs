using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace DisplayInputSwitch;
internal sealed class PhysicalMonitor : IDisposable {
    public IntPtr Handle;
    public string Serial = "";
    public string Name = "";
    public void Dispose() { if (Handle != IntPtr.Zero) { Ddc.DestroyPhysicalMonitor(Handle); Handle = IntPtr.Zero; } }
}
internal sealed record Outcome(string Serial, bool Ok, int? Input, int? Brightness, int? MaxBrightness, string? Error);
internal sealed record BrightnessReading(string Serial, string Name, int Current, int Maximum);
internal static class Ddc {
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct MonitorInfo {
        public int Size; public Rect Monitor, Work; public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct DisplayDevice {
        public int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Key;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct NativePhysical {
        public IntPtr Handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
    }
    internal delegate bool MonitorCallback(IntPtr monitor, IntPtr dc, ref Rect rect, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr rect, MonitorCallback callback, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint number, ref DisplayDevice info, uint flags);
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);
    [DllImport("dxva2.dll", CharSet = CharSet.Unicode)] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] NativePhysical[] physical);
    [DllImport("dxva2.dll")] internal static extern bool DestroyPhysicalMonitor(IntPtr monitor);
    [DllImport("dxva2.dll", SetLastError = true)] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, out uint type, out uint current, out uint max);
    [DllImport("dxva2.dll", SetLastError = true)] static extern bool SetVCPFeature(IntPtr monitor, byte code, uint value);
    static string Serial(string path) {
        var parts = path.Split('#');
        if (parts.Length < 3 || !parts[0].EndsWith("DISPLAY", StringComparison.OrdinalIgnoreCase)) return "";
        using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Enum\DISPLAY\{parts[1]}\{parts[2]}\Device Parameters");
        return key?.GetValue("EDID") is byte[] edid ? Edid.Serial(edid) : "";
    }
    public static List<PhysicalMonitor> Open() {
        var result = new List<PhysicalMonitor>();
        try {
            Exception? enumerationError = null;
            var success = EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr dc, ref Rect r, IntPtr data) => {
              try {
                var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>(), Device = "" };
                if (!GetMonitorInfo(h, ref info) || !GetNumberOfPhysicalMonitorsFromHMONITOR(h, out uint count) || count == 0 || count > 16) return true;
                var native = new NativePhysical[count];
                if (!GetPhysicalMonitorsFromHMONITOR(h, count, native)) return true;
                var opened = native.Select(p => new PhysicalMonitor { Handle = p.Handle, Name = p.Description }).ToList();
                result.AddRange(opened); // Ownership is established before registry access can throw.
                var devices = new List<DisplayDevice>();
                for (uint i = 0; i < 16; i++) {
                    var d = new DisplayDevice { Size = Marshal.SizeOf<DisplayDevice>(), Name = "", Description = "", Id = "", Key = "" };
                    if (!EnumDisplayDevices(info.Device, i, ref d, 1)) break;
                    if ((d.Flags & 1) != 0) devices.Add(d);
                }
                // shortcut: ambiguous multi-physical handles are refused until a verified mapping is available.
                if (count == 1 && devices.Count == 1) opened[0].Serial = Serial(devices[0].Id);
                return true;
              } catch (Exception e) { enumerationError = e; return false; }
            }, IntPtr.Zero);
            if (enumerationError != null) throw enumerationError;
            if (!success) throw new Exception("Windows 无法枚举显示器。");
            return result;
        } catch { result.ForEach(p => p.Dispose()); throw; }
    }
    static PhysicalMonitor Find(List<PhysicalMonitor> monitors, string serial) {
        var matches = monitors.Where(m => m.Serial == serial).ToList();
        if (matches.Count != 1 || string.IsNullOrEmpty(serial)) throw new Exception($"显示器 {serial} 不可见、缺少 EDID 序列号或匹配不唯一；未发送本组请求。");
        return matches[0];
    }
    static int Read(PhysicalMonitor m, byte code) => Read(m, code, out _);
    static int Read(PhysicalMonitor m, byte code, out int maximum) {
        maximum = -1;
        if (!GetVCPFeatureAndVCPFeatureReply(m.Handle, code, out _, out uint value, out uint max) || value > 65535 || max > 65535) return -1;
        maximum = (int)max; return (int)value;
    }
    static bool Write(PhysicalMonitor m, byte code, int value) {
        bool first = SetVCPFeature(m.Handle, code, (uint)value);
        Thread.Sleep(50);
        bool second = SetVCPFeature(m.Handle, code, (uint)value);
        return first && second;
    }
    public static List<(string Serial, string Name, int? Input)> Inspect() {
        var monitors = Open();
        try { return monitors.Select(m => { int v = Read(m, 0x60); return (m.Serial, m.Name, v < 0 ? (int?)null : v & 255); }).ToList(); }
        finally { monitors.ForEach(m => m.Dispose()); }
    }
    public static List<BrightnessReading> InspectBrightness() {
        var monitors = Open();
        try { return monitors.Select(m => { int v = Read(m, 0x10, out int max); return new BrightnessReading(m.Serial, m.Name, v, max); }).ToList(); }
        finally { monitors.ForEach(m => m.Dispose()); }
    }
    public static List<Outcome> Apply(List<Operation> ops) {
        Operation.Validate(ops);
        var monitors = Open();
        try {
            var plan = ops.Select(o => (Op: o, Monitor: Find(monitors, o.Serial))).ToList();
            var targets = new Dictionary<string, int>();
            foreach (var (o, m) in plan) {
                if (o.Brightness is int percent) {
                    int current = Read(m, 0x10, out int maximum);
                    _ = Brightness.Percent(current, maximum); // Preflight every brightness target before any write.
                    targets[o.Serial] = Brightness.Raw(percent, maximum);
                } else targets[o.Serial] = o.Input!.Value;
            }
            var errors = new Dictionary<string, string>();
            foreach (var (o,m) in plan) if (!Write(m, o.Brightness != null ? (byte)0x10 : (byte)0x60, targets[o.Serial])) errors[o.Serial] = "DDC 发送失败，可能部分执行；请检测后重试。";
            Thread.Sleep(600);
            var outcomes = new List<Outcome>();
            foreach (var (o,m) in plan) {
                bool brightness = o.Brightness != null;
                int current = Read(m, brightness ? (byte)0x10 : (byte)0x60, out int maximum);
                errors.TryGetValue(o.Serial, out string? error);
                int? validBrightness = null, validMaximum = null;
                if (brightness) {
                    if (current >= 0 && maximum > 0 && current <= maximum) {
                        validBrightness = current; validMaximum = maximum;
                        if (current != targets[o.Serial]) error ??= "亮度回读未达到目标；请检查 HDR、预设模式或其他控制工具。";
                    } else error ??= "亮度请求已发送，但无法读取确认。";
                }
                outcomes.Add(new Outcome(o.Serial, error == null, !brightness && current >= 0 ? current & 255 : null, validBrightness, validMaximum, error));
            }
            return outcomes;
        } finally { monitors.ForEach(m => m.Dispose()); }
    }
}
